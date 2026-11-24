import Foundation
import SenseCore
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `AgentScreenPreview.swift` | shared screen/room text projection |

public enum AgentScreenPreview {
    public static func tabs(_ layout: SurfaceLayoutAvailability, profile: String?) -> [String] {
        AgentWorkspaceScreenPreview.tabs(layout, profile: profile)
    }
    public static let watchedPaths = AgentWorkspaceScreenPreview.watchedPaths

    public static func glance(pages: PartFaces, dataRoot: URL, scope: String, jobs: AgentJobStore, invocation: ChatToolInvocation) async -> String? {
        await AgentWorkspaceScreenPreview.glance(workspace: ChatWorkspaceBinding.operation(turn: nil, invocation: invocation, jobs: jobs),
            pages: pages, dataRoot: dataRoot, scope: scope)
    }

    public static func render(_ room: String, dataRoot: URL, scope: String, jobs: AgentJobStore, invocation: ChatToolInvocation) async -> String {
        await AgentWorkspaceScreenPreview.render(workspace: ChatWorkspaceBinding.operation(turn: nil, invocation: invocation, jobs: jobs),
            room, dataRoot: dataRoot, scope: scope)
    }
    /// Use the same pane for the visible tab and the agent page reader.
    @MainActor
    public static func paneText(_ room: String, pages: PartFaces, root: URL, scope: String, jobs: AgentJobStore, invocation: ChatToolInvocation) async -> String {
        let said = await AgentScreenPreview.glance(pages: pages, dataRoot: root, scope: scope, jobs: jobs, invocation: invocation)
        let text = await AgentScreenPreview.render(room, dataRoot: root, scope: scope, jobs: jobs, invocation: invocation)
        return (said ?? "(no glance this turn)") + "\n\n" + text
    }
}
