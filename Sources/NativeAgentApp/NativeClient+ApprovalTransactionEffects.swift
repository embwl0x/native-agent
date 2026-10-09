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
        let fileAccess = ChatToolSessionContext.fileAccess
            ?? UserDefaults.standard.string(forKey: "chatFileAccess") ?? "read_only"
        try await BackgroundLoopsAssembly.makeTurnContinuationRuntime(dataRoot: dataRoot)
            .continueChatToolApproval(sessionID: sessionID, envelope: envelope, prompt: prompt, fileAccess: fileAccess) {
                let options = NativeChatTurnOptions.current(surface: envelope.surface)
                return (nil, options.serviceTier)
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
