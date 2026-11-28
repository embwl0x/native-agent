import SenseCore
import DeskCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `EngineHome.swift` | Home's packet read for `native-home` with the cognition runtime's attention reading; its rows' keys carry their calls |

extension NativeAgentEngine {
    /// What `native-home` draws Home from. The attention reading is the cognition runtime's own: asleep or awake, and unavailable when no runtime
    /// runs, never a guess.
    @MainActor func homePacketRead() -> PartFaces.PacketRead {
        let workspace = ChatWorkspaceBinding.operation(turn: nil, invocation: ChatToolInvocation().with(\.bodyField, bodyField), jobs: agentJobs.store)
        let owner = HomeFace.Owner(workspace: workspace, dataRoot: dataRoot) { [weak pages] in
            await pages?.refresh(page: "home")
        }
        // The mind is read at each draw: Home drawn before setup finished sees the mind once it runs.
        return { [layout, owner, mind] in
            let availability = await MainActor.run { layout.availability }
            let attention = await mind?.runtime?.homeAttention ?? .object(["state": .string("unavailable")])
            return await owner.read(layout: availability, attention: attention)
        }
    }
}

extension NativeCognitionRuntime {
    fileprivate var homeAttention: JSONValue {
        .object(["state": .string(isAsleep ? "asleep" : "awake"), "at": .string(HomeFace.clock(Date()))])
    }
}
