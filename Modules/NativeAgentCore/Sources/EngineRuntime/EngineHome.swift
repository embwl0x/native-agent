import AgentConversations
import AgentWorkspace
import AuthoredCapabilities
import ChatToolRuntime
import Cognition
import Desk
import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `EngineHome.swift` | Home's packet read for `native-home` with the cognition runtime's attention reading; its rows' keys carry their calls |

extension NativeAgentEngine {
    /// What `native-home` draws Home from. The attention reading is the cognition runtime's own: asleep or awake, and unavailable when no runtime
    /// runs, never a guess.
    @MainActor func homePacketRead() -> PartFaces.PacketRead {
        let workspace = ChatWorkspaceBinding.operation(turn: nil, invocation: ChatToolInvocation())
        let owner = HomeFace.Owner(workspace: workspace, dataRoot: dataRoot) { [weak pages] in
            await pages?.refresh(page: "home")
        }
        HomeFace.bind(dataRoot: dataRoot) { [weak pages] in await pages?.refresh(page: "home") }
        return { [layout, owner, cognition] in
            let availability = await MainActor.run { layout.availability }
            let attention: String
            if let cognition { attention = await cognition.isAsleep ? "asleep" : "awake" } else { attention = "unavailable" }
            return await owner.read(layout: availability, attention: attention)
        }
    }
}
