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
    /// A self-improvement card (no digest) may be hers to approve under Full
    /// Mac, so it never admits a script; User's script install card admits its digest.
    func enableSkill(name: String, reviewedDigest: String?) async throws {
        try await client.enableSkill(name: name, reviewedDigest: reviewedDigest, admitScript: reviewedDigest != nil)
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

    func continueChatToolApproval(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String) async throws {
        // The steer and file access the card carried, bound by the
        // coordinator; Telegram runs the turn on its own queue, so they are
        // carried in by hand. A card with no file access predates the record:
        // the chat's current setting, never a wider one by default.
        let steer = PeerDataTaint.current ?? PeerDataTaint()
        let fileAccess = ChatToolSessionContext.fileAccess
            ?? UserDefaults.standard.string(forKey: "chatFileAccess") ?? "read_only"
        let operation: @Sendable () async throws -> Void = {
            try await PeerDataTaint.$current.withValue(steer) {
                try await self.runApprovalFollowUp(dataRoot: dataRoot, sessionID: sessionID,
                    envelope: envelope, prompt: prompt, fileAccess: fileAccess)
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
                text: prompt, operation: { try await TurnAdmission.shared.run(sessionID: sessionID, operation: operation) })
        default:
            // Every door admits ordinary turns in this session here.
            try await TurnAdmission.shared.run(sessionID: sessionID, operation: operation)
        }
    }

    /// Her normal tools on the card's own door (Wave 2 #8): Trust, the peer
    /// floor and the steer bound around this turn judge every call in it.
    private func runApprovalFollowUp(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String,
                                     fileAccess: String) async throws {
        let door = ConversationSurfaceProfile(envelope.surface)
        // A card from Claude's or Codex's own bridge lane is that agent's
        // ask, whatever the card recorded (their lanes latch no steer of
        // their own), so the follow-up is held to the peer floor for it.
        if let lane = ["claude-bridge": "claude", "codex-bridge": "codex"][door.id] {
            PeerDataTaint.current?.mark(peer: lane)
        }
        let profile: NativeAgentAppChatSurfaceProfile = door.isAgentBridge || ["claude-bridge", "codex-bridge"].contains(door.id)
            ? .bridge : door.isIOSRemote ? .ios : NativeAgentAppChatSurfaceProfile(rawValue: door.id) ?? .mac
        let client = NativeAgentEngine.live.chatClient(profile: profile,
            approvalFiler: profile == .telegram ? TelegramApprovalFilerRef.shared.current() : nil)
        let options = NativeChatTurnOptions.current(surface: envelope.surface)
        let response = try await TurnRequest(message: prompt, sessionID: sessionID, fileAccess: fileAccess, persona: options.persona,
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
