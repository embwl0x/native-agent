import Agents
import BackgroundWork
import ChatOrchestration
import CryptoKit
import Desk
import Foundation
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import StandingBots
import TelegramBot
import TrustCenter
import WorkshopExecution

/// Continuations use the same admitted turn and reply path; Desk receipts and
/// approval claims retain their own settlement and retry rules.
public struct TurnContinuationRuntime: Sendable {
    private let dataRoot: URL
    private let engine: NativeAgentEngine
    private let telegramApprovalFiler: @Sendable () -> (any ApprovalFiler)?
    private let makeSender: @Sendable (@escaping @Sendable (TelegramConfig, Int) -> Bool) -> any AgentBridgeCompletionSending

    public init(dataRoot: URL, engine: NativeAgentEngine, telegramApprovalFiler: @escaping @Sendable () -> (any ApprovalFiler)? = { nil },
                makeSender: @escaping @Sendable (@escaping @Sendable (TelegramConfig, Int) -> Bool) -> any AgentBridgeCompletionSending) {
        self.dataRoot = dataRoot
        self.engine = engine
        self.telegramApprovalFiler = telegramApprovalFiler
        self.makeSender = makeSender
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
            correlationId: text(record.replyRoute, "correlationId"))
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
            let delivery = try await settleReply(response: response, route: route, envelope: envelope,
                settlement: .desk(deliveryID: "desk-continuation.\(current.originRunID).\(item.handle).\(current.resumeCount)",
                    cached: cached))
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
        guard record.surface == "bot" else {
            _ = try await runAdmittedContinuation(sessionID: record.sessionID ?? record.runID) {
                try await request.chat(on: client)
            }
            return
        }
        guard let saved = record.helperDefinition,
              let bot = try? JSONDecoder().decode(BotDefinition.self, from: saved.serializedData(pretty: false)),
              bot.sessionID == record.sessionID else {
            try await journal.block(reason: "helper_context_required")
            return
        }
        let runner = BotRunner(dataRoot: dataRoot, session: { bot, message in
            let choice = ProviderTurnChoice(provider: bot.provider ?? "", model: bot.model ?? "",
                reasoningEffort: bot.reasoningEffort ?? "", fast: bot.fast ?? false)
            return try await StandingBotContinuity.$currentBot.withValue(bot) {
                try await runAdmittedContinuation(sessionID: bot.sessionID) {
                    try await request.bind {
                        let response = try await client.chat(message: message, sessionId: bot.sessionID,
                            choice: choice, tokenLimit: bot.budget.tokens, surface: request.surface,
                            fileAccess: request.fileAccess, suppressUserAppend: true, mechanicalRow: .botReceipt)
                        return StandingBotContinuity.reply(response)
                    }
                }
            }
        })
        do {
            _ = try await runner.resume(bot: bot, message: request.message, holdUnattended: { _ in
                !(await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot))
            })
        } catch {
            try await journal.block(reason: "helper_continuation_refused")
            throw error
        }
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
        // A card from Claude's or Codex's own bridge lane is that agent's
        // ask, whatever the card recorded (their lanes latch no steer of
        // their own), so the follow-up is held to the peer floor for it.
        if let lane = ["claude-bridge": "claude", "codex-bridge": "codex"][door.id] {
            PeerDataTaint.current?.mark(peer: lane)
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
            replyTo: saved.replyTo, correlationId: saved.correlationId)
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

    private func runAdmittedContinuation<T: Sendable>(sessionID: String,
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
        case desk(deliveryID: String, cached: JSONValue)
        case approvalClaim
    }

    private func settleReply(response: ChatResponse, route: AgentBridgeCompletionRoute, envelope: TurnEnvelope,
                             settlement: ReplySettlement) async throws -> String {
        let requiresDestinationMatch: Bool
        switch settlement {
        case .desk: requiresDestinationMatch = true
        case .approvalClaim: requiresDestinationMatch = false
        }
        let sender = makeSender { config, chatID in
            (!requiresDestinationMatch || route.destinationId == envelope.verifiedChatId)
                && TelegramPollLoop.inboundAuthorizationDecision(
                    allowedChatIds: config.allowedChatIds, allowedUserIds: config.allowedUserIds,
                    chatId: chatID, fromUserId: envelope.verifiedUserId.flatMap(Int.init)
                ) == .allowed
        }
        switch settlement {
        case .desk(let deliveryID, let cached):
            let digest = SHA256.hash(data: try cached.serializedData(pretty: false)).map { String(format: "%02x", $0) }.joined()
            let lifecycle = CodexCompletionLifecycle(
                receiptURL: dataRoot.appendingPathComponent("chat/human-reply-delivery/receipts.jsonl"),
                ownerInstanceId: CodexCompletionLifecycle.processOwnerInstanceId, dataRoot: dataRoot)
            _ = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
            let delivery = await AgentBridgeCompletionRouter.deliver(
                deliveryId: deliveryID, requestDigest: digest, text: response.output,
                attachments: response.attachments ?? [], route: route, sender: sender, lifecycle: lifecycle)
            return delivery.status
        case .approvalClaim:
            // The approval claim already covers the turn and its single send.
            // Delivery failure never admits another model turn.
            let surface = route.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let artifacts = try AgentBridgeCompletionRouter.artifacts(deliveryId: response.runId,
                surface: surface, text: response.output, attachments: response.attachments ?? [])
            try await sender.preflight(surface: surface, route: route, artifacts: artifacts)
            for artifact in artifacts {
                switch await sender.send(artifact: artifact, idempotencyKey: artifact.id, surface: surface, route: route) {
                case .accepted: break
                case .rejected(let reason, _), .ambiguous(let reason):
                    throw NSError(domain: "ApprovalContinuationDelivery", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: reason])
                }
            }
            return "completed"
        }
    }
}
