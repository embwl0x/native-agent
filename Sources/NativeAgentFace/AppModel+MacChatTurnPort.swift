import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+MacChatTurnPort.swift` | Renderer Stop requests; execution, continuations and turn settlement belong to the body |

@MainActor
extension AppModel {
    func stopChatStream(sessionId: String? = nil) {
        let session = sessionId ?? activeChatSessionId
        Task { await requestChatStop(session: session) }
    }

    func requestChatStop(session: String) async {
        do {
            guard case .acknowledged = try await chatAct(.stop(session: session, expectedTurn: nil)) else {
                throw chatProtocolFailure("a Stop acknowledgement.")
            }
        } catch { setFailureStatus(error, action: "stop the conversation") }
    }
}
