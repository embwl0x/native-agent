import SelfImprovement
import Foundation
import PersistenceCore
import NativeAgentShared
import ApprovalTransactions
import ApprovalInbox
import ChatOrchestration
import MemoryV2
import TrustCenter
import WorkshopExecution
import Agents
import TelegramBot
import SlackBot
import DeviceSync

/// Host bindings for approval effects and mounted conversation refresh.
struct NativeClientApprovalTransactionEffects: ApprovalTransactionEffects {
    let client: NativeClient

    var telegramSurface: String { NativeAgentAppChatSurfaceProfile.telegram.rawValue }
    var telegramIncludesEvolutionBridge: Bool { NativeAgentAppChatSurfaceProfile.telegram.includesEvolutionBridge }

    func runMemoryHygiene() async throws -> ApprovalMemoryHygieneResult {
        let report = try await client.runMemoryHygiene()
        return ApprovalMemoryHygieneResult(id: report.id, status: report.status,
                                          reason: report.reason, consolidationRunId: report.consolidationRunId)
    }

    func disableSkill(name: String) async throws { try await client.disableSkill(name: name) }
    func enableSkill(name: String) async throws { try await client.enableSkill(name: name) }

    func reconcileSkillEvolutionRecall(memory: SwiftNativeMemoryV2, dataRoot: URL, personaRoot: URL) async throws {
        try await NativeClient.reconcileSkillEvolutionRecall(memory: memory, dataRoot: dataRoot, personaRoot: personaRoot)
    }

    func applyResolvedExternalSend(from record: ApprovalRecord) async -> Bool {
        await NativeClient.applyResolvedExternalSend(from: record).shouldArchiveVisibleCard
    }

    func selfEvolutionDependencies() -> SelfEvolutionApprovalExecutor.SelfEvolutionDeps {
        NativeClient.selfEvolutionDeps()
    }

    func runConnectorAction(descriptor: ConnectorActionDescriptor, dryRun: Bool, input: [String: JSONValue],
                            approvedReplayApprovalID: String, dataRoot: URL) async throws -> ApprovalConnectorActionResult {
        let receipt = try await client.runConnectorAction(descriptor: descriptor, dryRun: dryRun, input: input,
                                                        approvedReplayApprovalID: approvedReplayApprovalID, dataRoot: dataRoot)
        return ApprovalConnectorActionResult(id: receipt.id, status: receipt.status)
    }

    func toolDispatchClient(includeEvolutionBridge: Bool, denyExternalMcp: Bool,
                            enforceAppAutonomy: Bool) -> any ToolDispatchClient {
        NativeAgentEngine.live.toolDispatchClient(includeEvolutionBridge: includeEvolutionBridge,
                                                 denyExternalMcp: denyExternalMcp, enforceAppAutonomy: enforceAppAutonomy)
    }

    func continueChatToolApproval(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String,
                                  tools: any ToolDispatchClient) async throws {
        let operation: @Sendable () async throws -> Void = {
            try await ApprovalTransactionCoordinator.ApprovalReceiptTools.withTransientLoadout {
                try await self.runApprovalFollowUp(dataRoot: dataRoot, sessionID: sessionID,
                    envelope: envelope, prompt: prompt, tools: tools)
            }
        }
        switch envelope.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "telegram":
            let threadID = envelope.replyRoute.threadId.flatMap(Int.init)
            guard let rawChatID = envelope.verifiedChatId, let chatID = Int(rawChatID),
                  envelope.replyRoute.destinationId == rawChatID,
                  envelope.replyRoute.threadId == nil || threadID != nil else {
                throw NSError(domain: "ApprovalContinuationAdmission", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The saved Telegram destination is unavailable."])
            }
            try await TelegramTurnCoordinator.shared.runApprovalContinuation(
                destination: TelegramDestination(chatId: chatID, threadId: threadID),
                text: prompt, operation: operation)
        case "chat", "app", "bot":
            try await NativeAgentEngine.live.turns.runtime.runAdmittedTurn(sessionID: sessionID, operation: operation)
        case "ios", "iphone", "phone", "mobile", "icloud":
            try await ICloudIncomingTurnForwarder.runAdmittedTurn(sessionID: sessionID, operation: operation)
        case "slack":
            try await SlackSocketModeLoop.runAdmittedTurn(sessionID: sessionID, operation: operation)
        default:
            // Builder bridges and agent peers already admit ordinary turns here.
            try await TurnAdmission.shared.run(sessionID: sessionID, operation: operation)
        }
    }

    private func runApprovalFollowUp(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String,
                                     tools: any ToolDispatchClient) async throws {
        let client = NativeAgentEngine.live.chatClient(tools: tools)
        let options = NativeChatTurnOptions.current(surface: envelope.surface)
        let response = try await TurnRequest(message: prompt, sessionID: sessionID, fileAccess: "read_only", persona: options.persona,
                                  surface: envelope.surface, suppressUserAppend: true, envelope: envelope,
                                  verifiedSessionID: sessionID, verifiedChatID: .some(envelope.verifiedChatId),
                                  verifiedUserID: .some(envelope.verifiedUserId), replyRoute: envelope.replyRoute,
                                  serviceTier: .some(options.serviceTier)).chat(on: client)
        // The approval claim covers both the turn and its one delivery attempt.
        // A failed or uncertain send must never cause another model turn.
        let saved = envelope.replyRoute
        let deliverySurface = saved.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["telegram", "slack", "ios", "iphone", "mobile", "icloud"].contains(deliverySurface) else { return }
        let route = AgentBridgeCompletionRoute(surface: saved.surface, sessionId: sessionID,
            destinationId: saved.destinationId, threadId: saved.threadId, sourceKey: saved.sourceKey,
            replyTo: saved.replyTo, correlationId: saved.correlationId)
        let artifacts = try AgentBridgeCompletionRouter.artifacts(deliveryId: response.runId,
            surface: deliverySurface, text: response.output, attachments: response.attachments ?? [])
        let sender = LiveAgentBridgeCompletionSender(dataRoot: dataRoot, authorizeTelegramReply: { config, chatID in
            TelegramPollLoop.inboundAuthorizationDecision(
                allowedChatIds: config.allowedChatIds, allowedUserIds: config.allowedUserIds,
                chatId: chatID, fromUserId: envelope.verifiedUserId.flatMap(Int.init)
            ) == .allowed
        })
        try await sender.preflight(surface: deliverySurface, route: route, artifacts: artifacts)
        for artifact in artifacts {
            switch await sender.send(artifact: artifact, idempotencyKey: artifact.id, surface: deliverySurface, route: route) {
            case .accepted: break
            case .rejected(let reason, _), .ambiguous(let reason):
                throw NSError(domain: "ApprovalContinuationDelivery", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: reason])
            }
        }
    }

    func chatTurnCompleted(sessionID: String?) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
        }
    }

    func observeBrowserMotorAction(runID: String, dataRoot: URL) async {
        await NativeClient.observeBrowserMotorAction(runID: runID, dataRoot: dataRoot)
    }

    func executeApprovedBrowserRun(from record: ApprovalRecord) async throws {
        try await NativeClient.executeApprovedBrowserRun(from: record)
    }

    func finishRejectedBrowserRun(from record: ApprovalRecord, status: String) async throws {
        try await NativeClient.finishRejectedBrowserRun(from: record, status: status)
    }

    func workshopExecutor() -> WorkshopExecutorLoop {
        WorkshopExecutorRef.shared.current() ?? BackgroundLoopsAssembly.makeWorkshopExecutor()
    }

    func updateVisibleNotificationInboxStatus(id: String, action: String) async -> Bool {
        await NativeClient.updateVisibleNotificationInboxStatus(id: id, action: action)
    }
}
