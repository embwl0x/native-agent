import Foundation
import CryptoKit
import BackgroundWork
import ChatOrchestration
import Desk
import Agents
import PersistenceCore
import WorkshopExecution
import TelegramBot
import TrustCenter
import StandingBots
import ProviderRouting

extension BackgroundLoopsAssembly {
    static func makeDeskContinuationScheduler(dataRoot: URL) -> DeskContinuationScheduler {
        let runner = SwiftNativeWorkshopRunner(root: dataRoot,
            planner: SwiftNativeWorkshopPlannerLLM(dataRoot: dataRoot, lifecycleObserver: NativeAgentEngine.liveCognition))
        return DeskContinuationScheduler(dataRoot: dataRoot,
            isAllowed: { await unattendedWorkAllowed(dataRoot: dataRoot) },
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
                    tools: NativeAgentEngine.live.toolDispatchClient(enforceAppAutonomy: false),
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
                try await resumeDeskContinuation(item: item, record: record, dataRoot: dataRoot)
            })
    }

    static func resumeDeskContinuation(item: DeskItem, record: DeskContinuation, dataRoot: URL) async throws {
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
                let client = NativeAgentEngine.live.chatClient(profile: profile)
                let request = TurnRequest(message: try DeskContinuationScheduler.prompt(item: item, record: record),
                    sessionID: record.sessionID, fileAccess: record.fileAccess, surface: record.surface, suppressUserAppend: true,
                    envelope: envelope, verifiedSessionID: .some(record.sessionID),
                    verifiedChatID: .some(envelope.verifiedChatId), verifiedUserID: .some(envelope.verifiedUserId),
                    replyRoute: route.chatToolReplyRoute, pinnedRunID: record.runID)
                _ = try await PeerDataTaint.$current.withValue(PeerDataTaint(restoring: peerSources)) {
                    try await DeskContinuationScope.$current.withValue(journal) {
                        try await runDeskContinuationRequest(request, record: record, client: client,
                            journal: journal, dataRoot: dataRoot)
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
            let lifecycle = CodexCompletionLifecycle(
                receiptURL: dataRoot.appendingPathComponent("chat/human-reply-delivery/receipts.jsonl"),
                ownerInstanceId: CodexCompletionLifecycle.processOwnerInstanceId, dataRoot: dataRoot)
            _ = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
            let delivery = await AgentBridgeCompletionRouter.deliver(
                deliveryId: "desk-continuation.\(current.originRunID).\(item.handle).\(current.resumeCount)", requestDigest: digest,
                text: response.output, attachments: response.attachments ?? [], route: route,
                sender: LiveAgentBridgeCompletionSender(dataRoot: dataRoot, authorizeTelegramReply: { config, chatID in
                    route.destinationId == envelope.verifiedChatId
                        && TelegramPollLoop.inboundAuthorizationDecision(
                            allowedChatIds: config.allowedChatIds, allowedUserIds: config.allowedUserIds,
                            chatId: chatID, fromUserId: envelope.verifiedUserId.flatMap(Int.init)
                        ) == .allowed
                }), lifecycle: lifecycle)
            if delivery.status == "completed" { try await journal.delivered() }
            else { try await journal.block(reason: "reply_delivery_\(delivery.status)") }
        } catch {
            let current = await journal.snapshot()
            if current.state == .running {
                try await journal.finish(state: Task.isCancelled ? .canceled : .ready,
                    reply: current.lastReply, reason: current.reason ?? "continuation_interrupted")
            }
            throw error
        }
    }

    private static func runDeskContinuationRequest(_ request: TurnRequest, record: DeskContinuation,
        client: SwiftNativeChatOrchestrationClient, journal: DeskContinuationTurn, dataRoot: URL) async throws {
        guard record.surface == "bot" else {
            _ = try await TurnAdmission.shared.run(sessionID: record.sessionID ?? record.runID) {
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
                try await TurnAdmission.shared.run(sessionID: bot.sessionID) {
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
                !(await unattendedWorkAllowed(dataRoot: dataRoot))
            })
        } catch {
            try await journal.block(reason: "helper_continuation_refused")
            throw error
        }
    }

    private static func continuationEnvelope(_ record: DeskContinuation) throws -> TurnEnvelope {
        guard let saved = TurnEnvelope.fromPersistedMetadata(.object(record.envelope)) else {
            throw DeskContinuationError.unavailable
        }
        return TurnEnvelope(surface: saved.surface, agent: saved.agent,
            verifiedChatId: saved.verifiedChatId, verifiedUserId: saved.verifiedUserId,
            commandSignatureVerified: record.commandSignatureVerified,
            deliveryRoute: saved.deliveryRoute, declaredRemote: record.declaredRemote)
    }

    private static func text(_ object: [String: JSONValue], _ key: String) -> String? {
        if case .string(let value)? = object[key] { return value }
        return nil
    }
}
