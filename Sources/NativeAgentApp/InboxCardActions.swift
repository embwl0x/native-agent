import EngineRuntime
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApprovalTransactions
import NotificationInbox
import ChatTurnRuntime
import BackgroundWork
// Blueprint: | `InboxCardActions.swift` | `AppInboxCardActionEffects`: mounted navigation and injected engine inbox; callers use the core inbox transaction directly |

/// Mounted presentation and live app bindings for the core inbox transaction.
struct AppInboxCardActionEffects: InboxCardActionEffects {
    let inbox: InboxFacade

    func interactionAction(id: String, action: String, dataRoot: URL, quiet: Bool) async throws {
        try await InteractionCardDelivery.act(id: id, action: action, dataRoot: dataRoot, quiet: quiet)
    }

    func resolveApproval(id: String, decision: String, dataRootOverride: URL?) async throws {
        _ = try await ApprovalExecution.app()
            .resolveApproval(id: id, decision: decision)
    }

    func inboxItems(dataRoot: URL) async throws -> [InboxItemRecord] {
        try await inbox.list()
    }

    func cleanUpDiskHygiene(dataRoot: URL) async throws -> String {
        try await NativeAgentEngine.cleanUpDiskHygiene(dataRoot: dataRoot)
    }

    func chatClient(dataRoot: URL) -> SwiftNativeChatOrchestrationClient {
        NativeAgentEngine.forRoot(dataRoot).chatClient(profile: .background)
    }

    @MainActor func openApprovals() async {
        NotificationCenter.default.post(name: .openApprovalsRequest, object: nil)
    }

    @MainActor func openDesk() async {
        NotificationCenter.default.post(name: .openCommandRouteRequest, object: "desk")
    }

    @MainActor func openChatDraft(_ draft: String) async {
        NotificationCenter.default.post(name: .openChatDraftRequest, object: draft)
    }

    @MainActor func openSpokenChat(_ sessionID: String) async {
        NotificationCenter.default.post(name: .openSpokenChatRequest, object: sessionID)
    }
}
