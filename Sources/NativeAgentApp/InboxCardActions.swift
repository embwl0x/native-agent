import EngineRuntime
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApprovalTransactions
import NotificationInbox
import ChatTurnRuntime
import BackgroundWork
import Experiences
import ChatToolRuntime
import ApprovalInbox
// Blueprint: | `InboxCardActions.swift` | `AppInboxCardActionEffects`: native navigation for core inbox transactions |

struct AppInboxCardActionEffects: InboxCardActionEffects {
    let inbox: InboxFacade

    func interactionAction(id: String, action: String, dataRoot: URL, quiet: Bool, turn: Turn) async throws {
        try await Self.answerRequest(id: id, action: action, dataRoot: dataRoot, quiet: quiet, turn: turn)
    }

    /// Provider requests open the same protected entry as Providers; other requests open their conversation.
    @MainActor
    private static func answerRequest(id: String, action: String, dataRoot: URL, quiet: Bool, turn: Turn) async throws {
        try await InlineInteractionDelivery.act(id: id, action: action, dataRoot: dataRoot, quiet: quiet, turn: turn) { pointer in
            guard let appModel = ApplicationLifetime.shared.appModel else {
                throw NSError(domain: "InteractionCard", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Open NativeAgent on your Mac to finish this request."
                ])
            }
            if let card = try await InlineInteractionResolver.interaction(id: pointer.interactionID,
                sessionID: pointer.sessionID, dataRoot: dataRoot), card.kind == .apiKey, card.secret == nil {
                _ = try await appModel.engine.signInProviderFace(InlineInteractionRegistry.canonicalProviderID(card.target))
                return
            }
            await appModel.refreshChatSessionIndex()
            guard let session = appModel.engine.transcripts.sessions.first(where: { $0.id == pointer.sessionID }),
                  try await InlineInteractionResolver.interaction(id: pointer.interactionID,
                    sessionID: pointer.sessionID, dataRoot: dataRoot) != nil else {
                throw NSError(domain: "InteractionCard", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "This request is unavailable. Refresh Activity and try again."
                ])
            }
            await appModel.selectChatSession(session)
            guard appModel.activeChatSessionId == pointer.sessionID else {
                throw NSError(domain: "InteractionCard", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "This request is unavailable. Refresh Activity and try again."
                ])
            }
            _ = ApplicationLifetime.shared.request(.sidebar(.chat))
        }
    }

    func resolveApproval(id: String, decision: String, dataRootOverride: URL?, turn: Turn) async throws {
        let provenance = try await ApprovalExecution.decisionProvenance(id: id, turn: turn,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
        _ = try await ApprovalExecution.app()
            .resolveApproval(id: id, decision: decision, provenance: provenance, turn: turn)
    }

    func inboxItems(dataRoot: URL) async throws -> [InboxItemRecord] {
        try await ForPerson.at(dataRoot).inbox()
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
