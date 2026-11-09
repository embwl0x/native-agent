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
// Blueprint: | `BodyInboxCardActions.swift` | Copied Inbox effects return through its pipe; draft receipts confirm the applied renderer edit |

struct BodyInboxCardActionEffects: InboxCardActionEffects {
    let call: @MainActor @Sendable (FaceCall) async throws -> FaceReply
    let renderer: UUID

    func interactionAction(id: String, action: String, dataRoot: URL, quiet: Bool, turn: Turn) async throws {
        try await answerRequest(id: id, action: action, dataRoot: dataRoot, quiet: quiet, turn: turn)
    }

    /// Provider requests open the same protected entry as Providers; other requests open their conversation.
    @MainActor
    private func answerRequest(id: String, action: String, dataRoot: URL, quiet: Bool, turn: Turn) async throws {
        try await InlineInteractionDelivery.act(id: id, action: action, dataRoot: dataRoot, quiet: quiet, turn: turn) { pointer in
            guard let card = try await InlineInteractionResolver.interaction(id: pointer.interactionID,
                sessionID: pointer.sessionID, dataRoot: dataRoot) else {
                throw PartCallError(code: "request_unavailable", message: "This request is unavailable. Refresh Activity.")
            }
            if card.kind == .apiKey, card.secret == nil {
                _ = try await NativeAgentEngine.forRoot(dataRoot).signInProviderFace(
                    InlineInteractionRegistry.canonicalProviderID(card.target), renderer: renderer)
                return
            }
            let reply = try await call(.openConversation(session: pointer.sessionID, message: nil))
            try Self.requirePresentation(reply)
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


    @MainActor func openApprovals() async throws { try await present(.navigate(.init(
        destination: .init(page: "inbox", item: nil, session: nil, message: nil), policy: .foreground))) }
    @MainActor func openDesk() async throws { try await present(.navigate(.init(
        destination: .init(page: "desk", item: nil, session: nil, message: nil), policy: .foreground))) }
    @MainActor func openChatDraft(_ draft: String) async throws { try Self.requireDraft(try await call(.prepareChatDraft(text: draft))) }
    @MainActor func openSpokenChat(_ sessionID: String) async throws {
        try await present(.openConversation(session: sessionID, message: nil))
    }

    @MainActor private func present(_ request: FaceCall) async throws {
        try Self.requirePresentation(try await call(request))
    }
    static func requirePresentation(_ reply: FaceReply) throws {
        switch reply {
        case .acknowledged, .effect: return
        case .navigation(let receipt) where receipt.disposition == .mounted || receipt.disposition == .queued: return
        case .failed(let failure), .refused(let failure): throw failure
        case .cancelled: throw CancellationError()
        default: throw PartCallError(code: "presentation_unconfirmed", message: "The requested window did not confirm presentation.")
        }
    }

    static func requireDraft(_ reply: FaceReply) throws {
        switch reply {
        case .composerEdit(let result) where result.disposition == .applied: return
        case .composerEdit:
            throw PartCallError(code: "composer_edit_conflict", message: "The composer changed. Its draft and attachments were preserved.")
        case .failed(let failure), .refused(let failure): throw failure
        case .cancelled: throw CancellationError()
        default: throw PartCallError(code: "draft_unconfirmed", message: "The requested window did not confirm the draft edit.")
        }
    }
}
