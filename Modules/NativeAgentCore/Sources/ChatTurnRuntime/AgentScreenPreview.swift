import AgentWorkspace
import Foundation
import NativeAgentCore
import NativeAgentShared
import ChatToolRuntime
// Blueprint: | `AgentScreenPreview.swift` | shared screen/room text projection |

public enum AgentScreenPreview {
    public static func tabs(_ layout: SurfaceLayoutAvailability, profile: String?) -> [String] {
        AgentWorkspaceScreenPreview.tabs(layout, profile: profile)
    }
    public static let watchedPaths = AgentWorkspaceScreenPreview.watchedPaths
    public static let didChange = AgentWorkspaceScreenPreview.didChange

    public static func glance(dataRoot: URL, scope: String, invocation: ChatToolInvocation) async -> String? {
        await AgentWorkspaceScreenPreview.glance(workspace: ChatWorkspaceBinding.operation(turn: nil, invocation: invocation),
            dataRoot: dataRoot, scope: scope)
    }

    public static func render(_ room: String, dataRoot: URL, scope: String, invocation: ChatToolInvocation) async -> String {
        await AgentWorkspaceScreenPreview.render(workspace: ChatWorkspaceBinding.operation(turn: nil, invocation: invocation),
            room, dataRoot: dataRoot, scope: scope)
    }
    /// Use the same pane for the visible tab and the agent page reader.
    @MainActor
    public static func paneText(_ room: String, root: URL, scope: String, invocation: ChatToolInvocation) async -> String {
        let said = await AgentScreenPreview.glance(dataRoot: root, scope: scope, invocation: invocation)
        let text = await AgentScreenPreview.render(room, dataRoot: root, scope: scope, invocation: invocation)
        return (said ?? "(no glance this turn)") + "\n\n" + text
    }
}
