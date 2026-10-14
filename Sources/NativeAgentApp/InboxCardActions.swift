import EngineRuntime
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApprovalTransactions
import NotificationInbox
import BackgroundWork
import ChatOrchestration

/// Mounted presentation and live app bindings for the core inbox transaction.
struct AppInboxCardActionEffects: InboxCardActionEffects {
    var heartbeatActionIDs: Set<String> { HeartbeatCardAction.ids }
    var heartbeatOpenApprovalsActionID: String { HeartbeatCardAction.openApprovals.rawValue }
    var heartbeatRepairActionID: String { HeartbeatCardAction.repair.rawValue }

    func interactionAction(id: String, action: String, dataRoot: URL, quiet: Bool) async throws {
        try await InteractionCardDelivery.act(id: id, action: action, dataRoot: dataRoot, quiet: quiet)
    }

    func resolveApproval(id: String, decision: String, dataRootOverride: URL?) async throws {
        _ = try await ApprovalTransactionCoordinator.app(dataRootOverride: dataRootOverride)
            .resolveApproval(id: id, decision: decision)
    }

    func inboxItems(dataRoot: URL) async throws -> [InboxItemRecord] {
        try await InboxFacade(dataRoot: dataRoot).list()
    }

    func primaryActionProjection(for item: InboxItemRecord) -> (opensApprovals: Bool, isProactive: Bool) {
        (item.fallbackPrimaryAction?.id == "open_approvals" || item.hasLinkedApproval, item.isProactiveCard)
    }

    func repairHeartbeatInboxItem(id: String, dataRoot: URL) async throws -> String {
        try await NativeAgentEngine.repairHeartbeatInboxItem(id: id, dataRoot: dataRoot)
    }

    func cleanUpDiskHygiene(dataRoot: URL) async throws -> String {
        try await NativeAgentEngine.cleanUpDiskHygiene(dataRoot: dataRoot)
    }

    func chatClient(dataRoot: URL) -> SwiftNativeChatOrchestrationClient {
        NativeAgentEngine.forRoot(dataRoot).chatClient(profile: .background)
    }

    func openApprovals() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .openApprovalsRequest, object: nil)
        }
    }

    func openDesk() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .openCommandRouteRequest, object: "desk")
        }
    }

    func openChatDraft(_ draft: String) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .openChatDraftRequest, object: draft)
        }
    }

    func openSpokenChat(_ sessionID: String) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .openSpokenChatRequest, object: sessionID)
        }
    }
}
