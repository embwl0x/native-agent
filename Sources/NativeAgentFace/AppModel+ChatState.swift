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


    var isBusy: Bool { turnPart("isBusy", for: activeChatSessionId) { $0?.isBusy == true } }
    var isChatStreaming: Bool { turnPart("isStreaming", for: activeChatSessionId) { $0?.isStreaming == true } }

}
