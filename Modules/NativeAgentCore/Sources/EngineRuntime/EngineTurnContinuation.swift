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
// Blueprint: | `EngineTurnContinuation.swift` | `TurnContinuationRuntime`; Shared admission and reply settlement |

/// Continuations share the admitted turn path; Desk receipts and approval claims retain their own settlement rules.
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

    public func makeDeskContinuationScheduler() -> DeskContinuationScheduler {
        return DeskContinuationScheduler(dataRoot: dataRoot,
            isAllowed: { await UnattendedWork.allowed(dataRoot: dataRoot) },
            verify: { step, record in
                // Verify whole-file writes against the checkpoint’s retained content digest.
                guard step.tool == "write_file", let reference = step.reference,
                      case .string(let path)? = reference["path"], path.hasPrefix("/"),
                      case .int(let bytes)? = reference["bytes"], case .string(let digest)? = reference["sha256"],
                      record.fileAccess != "none", let peerSources = record.peerSources else {
                    return .unknown("\(step.tool) has no domain verifier")
                }
                guard bytes >= 0 else { return .unknown("write_file checkpoint has a negative byte count") }
                let envelope = try continuationEnvelope(record)
                _ = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
                let dispatcher = makeGatedToolDispatchClient(
                    tools: engine.toolDispatchClient(enforceAppAutonomy: false),
                    fileAccess: record.fileAccess, dataRoot: dataRoot, verifiedSessionId: record.sessionID)
                let verification = TurnRequest(message: record.remainingWork, sessionID: record.sessionID,
                    fileAccess: record.fileAccess, surface: record.surface, envelope: envelope,
                    verifiedSessionID: .some(record.sessionID), verifiedChatID: .some(envelope.verifiedChatId),
                    verifiedUserID: .some(envelope.verifiedUserId))
                let turn = verification.turn().with(\.peerSteering, PeerDataTaint(restoring: peerSources))
                let invocation = ChatToolInvocation()
                var offset: Int64 = 0
                var version: String?
                var hash = SHA256()
                while true {
                    try Task.checkCancellation()
                    var input: [String: JSONValue] = ["path": .string(path), "max_bytes": .int(200_000),
                        "offset": .int(offset), "raw": .bool(true)]
                    if let version { input["version"] = .string(version) }
                    let receipt = try await dispatcher.dispatch(tool: "read_file", input: input, surface: record.surface, turn: turn, invocation: invocation)
                    guard case .object(let fields) = receipt else {
                        return DeskContinuationScheduler.Verdict.unknown("write_file \(path) observation returned no read receipt")
                    }
                    guard fields["ok"] == .bool(true) else {
                        let cause = fields["error"]?.stringValue ?? "read receipt omitted its failure cause"
                        return .unknown("write_file \(path) could not be observed: \(cause)")
                    }
                    guard fields["offset"] == .int(offset),
                          case .string(let observedVersion)? = fields["version"], !observedVersion.isEmpty,
                          version == nil || version == observedVersion,
                          case .int(let total)? = fields["bytes"], total >= 0,
                          case .bool(let hasMore)? = fields["has_more"],
                          case .string(let content)? = fields["content"] else {
                        return .unknown("write_file \(path) observation is incomplete or changed between windows")
                    }
                    guard total == bytes else { return .unknown("write_file \(path) byte count does not match the checkpoint") }
                    let chunk: Data?
                    if fields["encoding"] == .string("base64") { chunk = Data(base64Encoded: content) }
                    else { chunk = Data(content.utf8) }
                    guard let chunk, fields["returned_bytes"] == .int(Int64(chunk.count)) else {
                        return .unknown("write_file \(path) observation did not preserve the returned bytes")
                    }
                    let next = offset.addingReportingOverflow(Int64(chunk.count))
                    guard !next.overflow, next.partialValue <= total,
                          hasMore ? (!chunk.isEmpty && next.partialValue < total) : next.partialValue == total else {
                        return .unknown("write_file \(path) observation has incomplete byte coverage")
                    }
                    hash.update(data: chunk)
                    if !hasMore {
                        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
                            return .unknown("write_file \(path) does not match the checkpointed content")
                        }
                        return .settled("write_file \(path) matches the checkpointed content digest")
                    }
                    offset = next.partialValue
                    version = observedVersion
                }
            },
            resume: { item, record in
                try await resumeDeskContinuation(item: item, record: record)
            })
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
        let turn = request.turn(id: checkpoint.turnId, parent: parent)
            .with(\.peerSteering, PeerDataTaint(restoring: sources))
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
        let parent = Turn(run: record.runID, session: record.sessionID)
            .with(\.peerSteering, PeerDataTaint(restoring: peerSources)).with(\.verifiedSessionID, record.sessionID)
            .with(\.envelope, envelope).with(\.fileAccess, record.fileAccess)
        do {
            let turn: Turn
            if record.reason != "reply_ready" {
                let client = engine.chatClient(profile: profile)
                let cue = try await engine.tools.withPartDoor(envelope: .native("desk_continuation:" + item.handle + ":" + record.runID),
                    turn: parent, continuation: journal) { door in
                    try await DeskContinuationScheduler.prompt(item: item, record: record, dataRoot: dataRoot,
                        invocation: door.invocation)
                }
                let request = followUpRequest(message: cue,
                    sessionID: record.sessionID, fileAccess: record.fileAccess, surface: record.surface, envelope: envelope,
                    replyRoute: route.chatToolReplyRoute, pinnedRunID: record.runID)
                turn = request.turn(parent: parent)
                try await runDeskContinuationRequest(request, record: record, client: client, journal: journal, turn: turn)
            } else { turn = parent }
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
            let delivery = try await settleReply(response: response, route: route, envelope: envelope, turn: turn,
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
        client: SwiftNativeChatOrchestrationClient, journal: DeskContinuationTurn, turn: Turn) async throws {
        do {
            _ = try await runOwnedContinuation(request, helperDefinition: record.helperDefinition, turn: turn, journal: journal) { turn in
                try await client.chat(message: request.message, sessionId: request.sessionID, model: request.model,
                    reasoningEffort: request.reasoningEffort, fileAccess: request.fileAccess, attachments: request.attachments,
                    persona: request.persona, surface: request.surface, suppressUserAppend: request.suppressUserAppend,
                    progress: nil, turn: turn, serviceTier: request.serviceTier ?? nil, work: .init(journal: journal))
            }
        } catch {
            if record.surface == "bot" { try await journal.block(reason: "helper_continuation_refused") }
            throw error
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
        guard let saved = helperDefinition,
              let bot = try? JSONDecoder().decode(BotDefinition.self, from: saved.serializedData(pretty: false)),
              bot.sessionID == request.sessionID else {
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

    private func continuationEnvelope(_ record: DeskContinuation) throws -> TurnEnvelope {
        guard let saved = TurnEnvelope.fromPersistedMetadata(.object(record.envelope)) else {
            throw DeskContinuationError.unavailable
        }
        return TurnEnvelope(surface: saved.surface, agent: saved.agent,
            verifiedChatId: saved.verifiedChatId, verifiedUserId: saved.verifiedUserId,
            commandSignatureVerified: record.commandSignatureVerified,
            deliveryRoute: saved.deliveryRoute, declaredRemote: record.declaredRemote,
            answerExperienceID: saved.answerExperienceID)
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
