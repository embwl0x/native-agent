import Foundation
import CoreGraphics
import ChatTurnRuntime
import AgentWorkspace
// Blueprint: | `MacChatScreenPreview.swift` | `TurnsFacade.receiveScreenPreview` publishes the runtime's transient preview vocabulary |

extension TurnsFacade {
    public func receiveScreenPreview(_ update: MacScreenPreviewUpdate, identity: MacChatTurnIdentity) {
        guard activeTurnIDsBySession[identity.sessionId] == identity.turnId,
              let merged = MacChatScreenPreview.merged(screenPreviewBySession[identity.sessionId], update: update)
        else { return }
        screenPreviewBySession[identity.sessionId] = merged
    }
}
