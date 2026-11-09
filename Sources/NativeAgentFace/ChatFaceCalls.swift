import AppKit
import Foundation
import NativeAgentShared
// Blueprint: | `ChatFaceCalls.swift` | Mounted conversation, detached-window, composer and acknowledged chat-draft reverse calls |

@MainActor
extension AppModel {
    func installChatFaceCalls(on router: FaceCallRouter) {
        DetachedChatWindowController.shared.attach(appModel: self)
        // Detached chats reopen in the window that owns them; her body draws none.
        DetachedChatWindowController.shared.restoreFromPersist()
        router.register({ [weak self] call in
            guard let self else { throw FaceWireError.disconnected }
            switch call {
            case .openConversation(let session, let message):
                guard await selectChatSession(id: session, userInitiated: false) else {
                    return .failed(WireFailure(code: "conversation_open_failed", message: statusText, cause: nil, effects: .unknown))
                }
                pendingChatMessageID = message
                ApplicationLifetime.shared.request(.sidebar(.chat))
                return .acknowledged
            case .openDetachedConversation(let session):
                return await DetachedChatWindowController.shared.open(sessionId: session)
            case .closeDetachedConversation(let session):
                DetachedChatWindowController.shared.close(sessionId: session)
                return .acknowledged
            case .readDetachedConversations:
                return .detachedSessions(DetachedChatWindowController.shared.detachedSessionIDs)
            case .readComposer(let session): return .composer(readFaceComposer(session: session))
            case .readComposerControls(let turn):
                let shell = QuietSelfAdmin.shared.composerCards
                let rows = shell.map { shell in
                    shell.activePane == nil ? [] : [shell.paneReadLine] + shell.rows.map { $0.label + ($0.isSelected ? " — selected" : "") }
                } ?? []
                return .composerControls(.init(openCard: shell?.activePane?.rawValue, rows: rows,
                    workPaneClosed: WorkPaneState.shared.userClosed(turnID: turn)))
            case .editComposer(let request): return .composerEdit(editFaceComposer(request))
            case .clearAcceptedComposer(let request): return .composerEdit(clearFaceAcceptedComposer(request))
            case .focusComposer(let session): return focusFaceComposer(session: session)
            case .openComposerCard(let name): return QuietComposerCommands.openFaceCard(name)
            case .closeComposerCard: return QuietComposerCommands.closeFaceCard()
            case .prepareChatDraft(let text): return .composerEdit(try await prepareChatDraft(text))
            default: return nil
            }
        }, disconnect: {
            for session in DetachedChatWindowController.shared.detachedSessionIDs {
                DetachedChatWindowController.shared.close(sessionId: session)
            }
        })
    }
}
