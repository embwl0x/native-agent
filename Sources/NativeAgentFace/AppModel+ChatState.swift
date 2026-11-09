import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `AppModel+ChatState.swift` | Drawing selections and explicit body refreshes; mounted views hold observations |

@MainActor
extension AppModel {
    func reloadPersonality() async { await refreshChatFace(.settings) }

    func refreshChatFace(_ scope: FaceRefreshScope) async {
        do {
            guard case .acknowledged = try await chatAct(.refresh(scope)) else {
                throw chatProtocolFailure("a refresh acknowledgement.")
            }
        } catch {
            guard !Task.isCancelled else { return }
            setFailureStatus(error, action: "refresh the conversation")
        }
    }

    func loadDetachedSessionMessages(_ sessionId: String) async { await refreshChatFace(.session(sessionId)) }

    func pinChatSessionForDetachedWindow(_ sessionId: String) async -> Bool {
        await performChatMutation(.pinConversation(session: sessionId), success: "Conversation pinned").succeeded
    }

    var isBusy: Bool { turnPart("isBusy", for: activeChatSessionId) { $0?.isBusy == true } }
    var isChatStreaming: Bool { turnPart("isStreaming", for: activeChatSessionId) { $0?.isStreaming == true } }

    var otherRunningChatSessionIDs: [String] {
        let active = activeChatSessionId
        return face.slot(.turns).select("otherRunning:\(active)", as: TurnSessionsFace.self) {
            $0?.streamingSessionIDs.filter { $0 != active }.sorted() ?? []
        }
    }
}
