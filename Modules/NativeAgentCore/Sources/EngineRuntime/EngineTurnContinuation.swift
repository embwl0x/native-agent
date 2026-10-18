import Agents
import AttentionRouting
import BackgroundWork
import BackgroundLoops
import ChatOrchestration
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
import SlackConnector
import DeviceSync
import Transcripts
import TrustCenter
import WorkshopExecution
import TurnTrace
import ApprovalTransactions

/// Continuations use the same admitted turn and reply path; Desk receipts and
/// approval claims retain their own settlement and retry rules.
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
        if checkpoint.capabilityProfile == "mac", checkpoint.surface == "chat", checkpoint.helperDefinition == nil {
            try await resumeMacTurn(checkpoint, self)
        } else { try await resumeTurn(checkpoint) }
    }

    /// User, 2026-10-01: what is said in the conversation he is in reaches his other
    /// doors — and only that conversation. After a turn User started there at the
    /// Mac, the phone or Slack (never an agent's, judged by the turn's user row),
    /// its reply goes to the Telegram chat bound to that session, and to the phone
    /// as a push unless the phone asked. A Telegram turn travels nowhere: Telegram
    /// already notifies his phone, and a second push doubled it. User, 2026-10-04:
    /// a Mac turn means he is at the Mac, so its Telegram copy lands silently and
    /// the phone gets no push, only the transcript snapshot every completion
    /// already publishes. Terminal settlement retains the exact mirror intent;
    /// the delivery-state event owner sends it without blocking the turn's stream.
    @MainActor
    public static func installReplyMirror() {
        AbandonedTurnReconciliationHook.installReplyMirror { root, session, run in
            try await retainMirrorIntent(sessionId: session, runId: run, dataRoot: root)
        }
    }

    private static let mirrorDoors = ["app": "Mac", "chat": "Mac", "ios": "iPhone", "slack": "Slack"]

    private static func mirrorLifecycle(dataRoot: URL) -> CodexCompletionLifecycle {
        CodexCompletionLifecycle(receiptURL: dataRoot.appendingPathComponent("chat/anchor-mirror/receipts.jsonl"),
            ownerInstanceId: CodexCompletionLifecycle.processOwnerInstanceId, dataRoot: dataRoot)
    }

    private static func retainMirrorIntent(sessionId: String, runId: String, dataRoot: URL, requiresAnchor: Bool = true) async throws {
        guard !requiresAnchor || sessionId == ConversationAnchor.currentSessionId(dataRoot: dataRoot),
              let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: sessionId, runId: runId),
              !response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
        let persistence = SwiftNativePersistenceCore()
        let read = try await persistence.withFileLock(path) { try await persistence.readJSONLReporting(path) }
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
            var mirror = response
            mirror.attachments = []
            try await lifecycle.cacheResponse(mirror, deliveryId: deliveryId, requestDigest: digest)
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
            _ = await AgentBridgeCompletionRouter.deliver(deliveryId: row.id, requestDigest: row.digest,
                text: text, attachments: [], route: route,
                sender: makeSender(surface == "app" || surface == "chat", route.correlationId, { config, chatID in
                    TelegramPollLoop.inboundAuthorizationDecision(allowedChatIds: config.allowedChatIds,
                        allowedUserIds: config.allowedUserIds, chatId: chatID, fromUserId: chatID > 0 ? chatID : nil) == .allowed
                }), lifecycle: lifecycle, notifyRequestedResult: surface == "slack")
        }
    }

    public func makeDeskContinuationScheduler() -> DeskContinuationScheduler {
        let runner = SwiftNativeWorkshopRunner(root: dataRoot,
            planner: SwiftNativeWorkshopPlannerLLM(dataRoot: dataRoot, lifecycleObserver: engine.cognition))
        return DeskContinuationScheduler(dataRoot: dataRoot,
            isAllowed: { await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot) },
            verify: { step, record in
                if step.owner == "workshop", let id = step.ownerID {
                    guard let execution = try await runner.getWorkshopExecution(id) else {
                        return .unknown("workshop execution \(id) not found")
                    }
                    if ["queued", "running", "pending"].contains(execution.status) { return .waiting }
                    guard execution.status == "completed", execution.verification?.status == .satisfied else {
                        return .unknown("workshop execution \(id) ended \(execution.status) without satisfied verification")
                    }
                    return .settled("workshop execution \(id) completed; verification satisfied")
                }
                // A whole-file write is verified by reading the file back and
                // matching the content digest the checkpoint kept.
                guard step.tool == "write_file", let reference = step.reference,
                      case .string(let path)? = reference["path"], path.hasPrefix("/"),
                      case .int(let bytes)? = reference["bytes"], case .string(let digest)? = reference["sha256"],
                      record.fileAccess != "none", let peerSources = record.peerSources else {
                    return .unknown("\(step.tool) has no domain verifier")
                }
                let envelope = try continuationEnvelope(record)
                _ = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
                let dispatcher = makeGatedToolDispatchClient(
                    tools: engine.toolDispatchClient(enforceAppAutonomy: false),
                    fileAccess: record.fileAccess, dataRoot: dataRoot, verifiedSessionId: record.sessionID)
                let verification = TurnRequest(message: record.remainingWork, sessionID: record.sessionID,
                    fileAccess: record.fileAccess, surface: record.surface, envelope: envelope,
                    verifiedSessionID: .some(record.sessionID), verifiedChatID: .some(envelope.verifiedChatId),
                    verifiedUserID: .some(envelope.verifiedUserId))
                let receipt = try await PeerDataTaint.$current.withValue(PeerDataTaint(restoring: peerSources)) {
                    try await verification.bind {
                        try await dispatcher.dispatch(tool: "read_file",
                            input: ["path": .string(path), "max_bytes": .int(bytes + 1)], surface: record.surface)
                    }
                }
                guard case .object(let fields) = receipt, fields["ok"] == .bool(true),
                      fields["truncated"] == .bool(false), case .string(let content)? = fields["content"],
                      SHA256.hash(data: Data(content.utf8)).map({ String(format: "%02x", $0) }).joined() == digest else {
                    return .unknown("write_file \(path) does not match the checkpointed content")
                }
                return .settled("write_file \(path) matches the checkpointed content digest")
            },
            resume: { item, record in
                try await resumeDeskContinuation(item: item, record: record)
            })
    }

    public func resumeTurn(_ checkpoint: TurnCheckpoint, progress: ChatOrchestrationProgressHandler? = nil) async throws {
        guard let surface = text(checkpoint.replyRoute, "surface") else { throw DeskContinuationError.unavailable }
        let route = AgentBridgeCompletionRoute(surface: surface, sessionId: checkpoint.sessionId,
            destinationId: text(checkpoint.replyRoute, "destinationId"), threadId: text(checkpoint.replyRoute, "threadId"),
            sourceKey: text(checkpoint.replyRoute, "sourceKey"), replyTo: text(checkpoint.replyRoute, "replyTo"),
            correlationId: text(checkpoint.replyRoute, "correlationId"), requesterUserId: text(checkpoint.replyRoute, "requesterUserId"))
        let resume: @Sendable () async throws -> Void = {
            try await resumeCheckpoint(checkpoint, route: route, progress: progress)
        }
        if route.kind == .callerResult {
            try await engine.agents.tasks.resume(route, runID: checkpoint.runId, operation: resume)
        } else { try await resume() }
    }

    private func resumeCheckpoint(_ checkpoint: TurnCheckpoint, route: AgentBridgeCompletionRoute,
                                  progress: ChatOrchestrationProgressHandler?) async throws {
        guard let saved = TurnEnvelope.fromPersistedMetadata(.object(checkpoint.envelope)),
              let name = checkpoint.capabilityProfile,
              let profile = NativeAgentAppChatSurfaceProfile(rawValue: name),
              let sources = checkpoint.peerSources else {
            throw DeskContinuationError.unavailable
        }
        let envelope = TurnEnvelope(surface: saved.surface, agent: saved.agent,
            verifiedChatId: saved.verifiedChatId, verifiedUserId: saved.verifiedUserId,
            commandSignatureVerified: checkpoint.commandSignatureVerified,
            deliveryRoute: saved.deliveryRoute, declaredRemote: checkpoint.declaredRemote)
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
        let response = try await PeerDataTaint.$current.withValue(PeerDataTaint(restoring: sources)) {
            try await DeskContinuationScope.$current.withValue(journal) {
                try await runOwnedContinuation(request, helperDefinition: checkpoint.helperDefinition) {
                    guard let current = try TurnCheckpoint.read(dataRoot: dataRoot,
                        sessionId: checkpoint.sessionId, turnId: checkpoint.turnId), current.updatedAt == checkpoint.updatedAt else {
                        throw DeskContinuationError.conflict
                    }
                    return try await client.resumeTurn(current, request: request, progress: progress)
                }
            }
        }
        if checkpoint.hasRedeliveryOwner {
            let digest = CodexCompletionTranscriptEvidence.responseDigest(sessionId: checkpoint.sessionId,
                runId: checkpoint.runId, content: response.output, attachments: response.attachments ?? [])
            guard try await settleReply(response: response, route: route, envelope: envelope,
                settlement: .durable(deliveryID: "turn-restart.\(checkpoint.runId)", requestDigest: digest, notifyRequestedResult: false)) == "completed" else { return }
            try checkpoint.remove(dataRoot: dataRoot)
        } else if checkpoint.helperDefinition == nil, let kind = route.kind, kind == .local || kind == .callerResult {
            // The reply is in the conversation: the chat showing it refreshes,
            // and the reply-delivery owner (the delegation outcome loop, which
            // reconciles the bridge's reply ledger from the transcript) hears
            // the conversation changed, so the caller's next read returns it
            // without waiting for the owner's integrity sweep.
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

    private func resumeDeskContinuation(item: DeskItem, record: DeskContinuation) async throws {
        let envelope = try continuationEnvelope(record)
        guard let peerSources = record.peerSources,
              let profileName = record.capabilityProfile,
              let profile = NativeAgentAppChatSurfaceProfile(rawValue: profileName),
              let surface = text(record.replyRoute, "surface"), !surface.isEmpty else {
            throw DeskContinuationError.unavailable
        }
        _ = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
        let route = AgentBridgeCompletionRoute(surface: surface, sessionId: record.sessionID,
            destinationId: text(record.replyRoute, "destinationId"), threadId: text(record.replyRoute, "threadId"),
            sourceKey: text(record.replyRoute, "sourceKey"), replyTo: text(record.replyRoute, "replyTo"),
            correlationId: text(record.replyRoute, "correlationId"), requesterUserId: text(record.replyRoute, "requesterUserId"))
        let journal = DeskContinuationTurn(store: SwiftNativeDeskStore(dataRoot: dataRoot), record: record, handle: item.handle)
        do {
            if record.reason != "reply_ready" {
                let client = engine.chatClient(profile: profile)
                let request = followUpRequest(message: try DeskContinuationScheduler.prompt(item: item, record: record),
                    sessionID: record.sessionID, fileAccess: record.fileAccess, surface: record.surface, envelope: envelope,
                    replyRoute: route.chatToolReplyRoute, pinnedRunID: record.runID)
                _ = try await PeerDataTaint.$current.withValue(PeerDataTaint(restoring: peerSources)) {
                    try await DeskContinuationScope.$current.withValue(journal) {
                        try await runDeskContinuationRequest(request, record: record, client: client,
                            journal: journal)
                    }
                }
            }
            let current = await journal.snapshot()
            guard current.reason == "reply_ready" else { return }
            guard let live = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items
                .first(where: { $0.handle == item.handle }), live.status != .canceled else {
                try await journal.finish(state: .canceled, reply: current.lastReply, reason: "task_canceled")
                return
            }
            guard let cached = current.response else {
                try await journal.block(reason: "reply_receipt_required")
                return
            }
            let response = try JSONDecoder().decode(ChatResponse.self, from: cached.serializedData(pretty: false))
            let digest = SHA256.hash(data: try cached.serializedData(pretty: false)).map { String(format: "%02x", $0) }.joined()
            let delivery = try await settleReply(response: response, route: route, envelope: envelope,
                settlement: .durable(deliveryID: "desk-continuation.\(current.originRunID).\(item.handle).\(current.resumeCount)",
                    requestDigest: digest, notifyRequestedResult: true))
            if delivery == "completed" { try await journal.delivered() }
            else { try await journal.block(reason: "reply_delivery_\(delivery)") }
        } catch {
            let current = await journal.snapshot()
            if current.state == .running {
                try await journal.finish(state: Task.isCancelled ? .canceled : .ready,
                    reply: current.lastReply, reason: current.reason ?? "continuation_interrupted")
            }
            throw error
        }
    }

    private func runDeskContinuationRequest(_ request: TurnRequest, record: DeskContinuation,
        client: SwiftNativeChatOrchestrationClient, journal: DeskContinuationTurn) async throws {
        do {
            _ = try await runOwnedContinuation(request, helperDefinition: record.helperDefinition) {
                guard let bot = StandingBotContinuity.currentBot else { return try await request.chat(on: client) }
                return try await request.bind {
                    try await client.chat(message: request.message, sessionId: bot.sessionID,
                        choice: ProviderTurnChoice.current, tokenLimit: bot.budget.tokens, surface: request.surface,
                        fileAccess: request.fileAccess, suppressUserAppend: true, mechanicalRow: .botReceipt)
                }
            }
        } catch {
            if record.surface == "bot" { try await journal.block(reason: "helper_continuation_refused") }
            throw error
        }
    }

    private func runOwnedContinuation(_ request: TurnRequest, helperDefinition: JSONValue?,
        operation: @escaping @Sendable () async throws -> ChatResponse) async throws -> ChatResponse {
        guard request.surface == "bot" else {
            return try await runAdmittedContinuation(sessionID: request.sessionID) { try await operation() }
        }
        guard let saved = helperDefinition,
              let bot = try? JSONDecoder().decode(BotDefinition.self, from: saved.serializedData(pretty: false)),
              bot.sessionID == request.sessionID else {
            throw DeskContinuationError.unavailable
        }
        let responses = AsyncStream<ChatResponse>.makeStream()
        defer { responses.continuation.finish() }
        let runner = BotRunner(dataRoot: dataRoot, session: { bot, _ in
            let choice = try await BotChatContract.choice(for: bot, dataRoot: self.dataRoot)
            return try await StandingBotContinuity.$currentBot.withValue(bot) {
                try await runAdmittedContinuation(sessionID: bot.sessionID) {
                    try await ProviderTurnChoice.$current.withValue(choice) {
                        let response = try await operation()
                        responses.continuation.yield(response)
                        return StandingBotContinuity.reply(response)
                    }
                }
            }
        })
        _ = try await runner.resume(bot: bot, message: request.message, holdUnattended: { _ in
                !(await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot))
            })
        responses.continuation.finish()
        var iterator = responses.stream.makeAsyncIterator()
        guard let response = await iterator.next() else { throw DeskContinuationError.unavailable }
        return response
    }

    private func continuationEnvelope(_ record: DeskContinuation) throws -> TurnEnvelope {
        guard let saved = TurnEnvelope.fromPersistedMetadata(.object(record.envelope)) else {
            throw DeskContinuationError.unavailable
        }
        return TurnEnvelope(surface: saved.surface, agent: saved.agent,
            verifiedChatId: saved.verifiedChatId, verifiedUserId: saved.verifiedUserId,
            commandSignatureVerified: record.commandSignatureVerified,
            deliveryRoute: saved.deliveryRoute, declaredRemote: record.declaredRemote)
    }

    private func text(_ object: [String: JSONValue], _ key: String) -> String? {
        if case .string(let value)? = object[key] { return value }
        return nil
    }

    public func continueChatToolApproval(sessionID: String, envelope: TurnEnvelope, prompt: String,
                                         fileAccess: String,
                                         turnOptions: @escaping @Sendable () -> (persona: String?, serviceTier: String?)) async throws {
        let steer = PeerDataTaint.current ?? PeerDataTaint()
        try await runApprovalAdmission(sessionID: sessionID, envelope: envelope, prompt: prompt) {
            try await PeerDataTaint.$current.withValue(steer) {
                try await runApprovalFollowUp(sessionID: sessionID, envelope: envelope, prompt: prompt,
                    fileAccess: fileAccess, turnOptions: turnOptions)
            }
        }
    }

    /// Her normal tools on the card's own door (Wave 2 #8): Trust, the peer
    /// floor and the steer bound around this turn judge every call in it.
    private func runApprovalFollowUp(sessionID: String, envelope: TurnEnvelope, prompt: String,
                                     fileAccess: String,
                                     turnOptions: @escaping @Sendable () -> (persona: String?, serviceTier: String?)) async throws {
        let door = ConversationSurfaceProfile(envelope.surface)
        // A named bridge's follow-up carries its verified principal, not its route name.
        if let lane = ["claude-bridge": "claude", "codex-bridge": "codex"][door.id] {
            PeerDataTaint.current?.mark(peer: envelope.verifiedUserId.map { "peer:" + $0 } ?? lane)
        }
        let profile: NativeAgentAppChatSurfaceProfile = door.isAgentBridge || ["claude-bridge", "codex-bridge"].contains(door.id)
            ? .bridge : door.isIOSRemote ? .ios : NativeAgentAppChatSurfaceProfile(rawValue: door.id) ?? .mac
        let client = engine.chatClient(profile: profile,
            approvalFiler: profile == .telegram ? telegramApprovalFiler() : nil)
        let options = turnOptions()
        let response = try await followUpRequest(message: prompt, sessionID: sessionID, fileAccess: fileAccess,
            surface: envelope.surface, envelope: envelope, replyRoute: envelope.replyRoute,
            persona: options.persona, serviceTier: .some(options.serviceTier)).chat(on: client)
        // The approval claim covers both the turn and its one delivery attempt.
        // A failed or uncertain send must never cause another model turn.
        let saved = envelope.replyRoute
        let deliverySurface = saved.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["telegram", "slack", "ios", "iphone", "mobile", "icloud"].contains(deliverySurface) else { return }
        let route = AgentBridgeCompletionRoute(surface: saved.surface, sessionId: sessionID,
            destinationId: saved.destinationId, threadId: saved.threadId, sourceKey: saved.sourceKey,
            replyTo: saved.replyTo, correlationId: saved.correlationId, requesterUserId: saved.requesterUserId)
        _ = try await settleReply(response: response, route: route, envelope: envelope, settlement: .approvalClaim)
    }

    private func followUpRequest(message: String, sessionID: String?, fileAccess: String, surface: String,
        envelope: TurnEnvelope, replyRoute: ChatToolSessionContext.ReplyRoute, pinnedRunID: String?? = nil,
        persona: String? = nil, serviceTier: String?? = nil) -> TurnRequest {
        TurnRequest(message: message, sessionID: sessionID, fileAccess: fileAccess, persona: persona,
            surface: surface, suppressUserAppend: true, envelope: envelope, verifiedSessionID: .some(sessionID),
            verifiedChatID: .some(envelope.verifiedChatId), verifiedUserID: .some(envelope.verifiedUserId),
            replyRoute: replyRoute, pinnedRunID: pinnedRunID, serviceTier: serviceTier)
    }

    private func runAdmittedContinuation<T: Sendable>(sessionID: String?,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await TurnAdmission.shared.run(sessionID: sessionID, operation: operation)
    }

    private func runApprovalAdmission(sessionID: String, envelope: TurnEnvelope, prompt: String,
        operation: @escaping @Sendable () async throws -> Void) async throws {
        guard envelope.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "telegram" else {
            try await runAdmittedContinuation(sessionID: sessionID, operation: operation)
            return
        }
        let threadID = envelope.replyRoute.threadId.flatMap(Int.init)
        guard let rawChatID = envelope.verifiedChatId, let chatID = Int(rawChatID),
              envelope.replyRoute.destinationId == rawChatID,
              envelope.replyRoute.threadId == nil || threadID != nil else {
            throw NSError(domain: "ApprovalContinuationAdmission", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The saved Telegram destination is unavailable."])
        }
        try await TelegramTurnCoordinator.shared.runApprovalContinuation(
            destination: TelegramDestination(chatId: chatID, threadId: threadID),
            text: prompt, operation: { try await runAdmittedContinuation(sessionID: sessionID, operation: operation) })
    }

    private enum ReplySettlement {
        case durable(deliveryID: String, requestDigest: String, notifyRequestedResult: Bool)
        case approvalClaim
    }

    private func settleReply(response: ChatResponse, route: AgentBridgeCompletionRoute, envelope: TurnEnvelope,
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
            switch try await lifecycle.claim(deliveryId: deliveryID, requestDigest: digest, sessionId: response.sessionId, responseRunId: response.runId, route: route) {
            case .start:
                try await lifecycle.cacheResponse(response, deliveryId: deliveryID, requestDigest: digest)
            case .cached: break
            case .inProgress:
                try await lifecycle.cacheResponse(response, deliveryId: deliveryID, requestDigest: digest)
            case .settled(let delivery):
                return delivery?.status == "sent_unconfirmed" || delivery?.status == "failed_before_answer" ? "completed" : delivery?.status ?? "completed"
            case .outcomeUnknown, .conflict: throw CodexCompletionLifecycle.LifecycleError.requestConflict
            }
            let delivery = await AgentBridgeCompletionRouter.deliver(
                deliveryId: deliveryID, requestDigest: digest, text: response.output,
                attachments: response.attachments ?? [], route: route, sender: sender, lifecycle: lifecycle,
                notifyRequestedResult: notifyRequestedResult)
            return ["sent_unconfirmed", "failed_before_answer"].contains(delivery.status) ? "completed" : delivery.status
        case .approvalClaim:
            let delivery = try await sender.deliverReply(response, deliveryId: response.runId, route: route,
                priorVerdict: nil, notifyRequestedResult: false)
            return delivery.status == "sent_unconfirmed" ? "completed" : delivery.status
        }
    }
}

public struct EngineAgentBridgeCompletionSender: AgentBridgeCompletionSending {
  let authorizeTelegramReply: (@Sendable (TelegramConfig, Int) -> Bool)?

  typealias DeliveryError = AgentBridgeCompletionRouter.DeliveryError

  private let engine: @Sendable () -> NativeAgentEngine
  private let router: @Sendable () -> AttentionRouter
  let dataRoot: URL
  /// Telegram text lands without a sound or alert (context, not a ping).
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
    try await AgentBridgeCompletionRouter.deliverReply(deliveryId: deliveryId, route: route,
      notifyRequestedResult: notifyRequestedResult, recoverTelegram: {
      guard let raw = route.destinationId, let chatID = Int(raw), response.sessionId != nil,
            let config = TelegramConfig.loadFromDisk(dataRoot: dataRoot), config.enabled,
            authorizeTelegramReply?(config, chatID) != false,
            route.threadId == nil || route.threadId.flatMap(Int.init) != nil,
            let loop = await BackgroundLoops.BackgroundLoopsManager.shared.loopRunner(loopId: "telegram_poll") as? TelegramPollLoop else {
        throw DeliveryError.invalidTelegramDestination
      }
      return try await loop.recoverReply(response, originRunId: response.runId,
        destination: TelegramDestination(chatId: chatID, threadId: route.threadId.flatMap(Int.init)),
        requesterUserId: route.requesterUserId.flatMap(Int.init), silent: silentTelegram, priorVerdict: priorVerdict)
    }, recoverSlack: {
      guard let loop = await BackgroundLoops.BackgroundLoopsManager.shared.loopRunner(loopId: "slack_socket_mode") as? SlackSocketModeLoop else {
        throw DeliveryError.missingSlackDestination
      }
      return try await loop.recoverReply(response, originRunId: response.runId, route: route, priorVerdict: priorVerdict)
    }, recoverIOS: {
      try await engine().deviceSync!.bridge.recoverReply(response, route: route, priorVerdict: priorVerdict)
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
      guard let config = TelegramConfig.loadFromDisk(dataRoot: dataRoot), config.enabled, !config.botToken.isEmpty,
            let raw = route.destinationId, let chatID = Int(raw), authorizeTelegramReply?(config, chatID) != false,
            route.threadId == nil || route.threadId.flatMap(Int.init) != nil else { throw DeliveryError.invalidTelegramDestination }
    case .slack: try SlackConnectorActions.requireConfiguredToken(dataRoot: dataRoot)
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

/// The running Telegram loop's approval filer, so an approval follow-up on
/// Telegram files its cards with the same inline buttons (Wave 2 #8).
public final class TelegramApprovalFilerRef: @unchecked Sendable {
    public static let shared = TelegramApprovalFilerRef()
    private let lock = NSLock()
    private var filer: TelegramApprovalFiler?

    public func configure(_ filer: TelegramApprovalFiler) {
        lock.withLock { self.filer = filer }
        ApprovalChatCards.useTelegram(filer)
    }
    public func current() -> TelegramApprovalFiler? { lock.withLock { filer } }
}
