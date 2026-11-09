import NativeAgentShared
import SwiftUI
// Blueprint: | `MacChatOtherSessionsBanner.swift` | Shared cross-conversation movement with existing navigation and Stop owners |

struct MacChatOtherSessionsBanner: View {
    @Environment(AppModel.self) private var appModel
    let sessionID: String
    var onGoTo: ((String) -> Void)? = nil

    var body: some View {
        TurnElsewhereLine(
            movements: appModel.turnSessionsFace?.movements(outside: sessionID) ?? [],
            agentName: appModel.agentDisplayName,
            open: onGoTo ?? { session in
                Task { @MainActor in
                    await appModel.selectChatSession(id: session)
                    guard appModel.activeChatSessionId == session else { return }
                    ApplicationLifetime.shared.request(.sidebar(.chat))
                }
            },
            stop: { appModel.stopChatStream(sessionId: $0) }
        )
    }
}
