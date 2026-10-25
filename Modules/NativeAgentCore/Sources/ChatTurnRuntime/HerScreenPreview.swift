import AgentWorkspace
import Foundation
import NativeAgentShared
// Blueprint: | `HerScreenPreview.swift` | shared screen/room text projection |

/// Binds the conversation and tool owners for the app's read-only screen door.
public enum HerScreenPreview {
    public static func tabs(_ layout: SurfaceLayout, profile: String?) -> [String] {
        AgentWorkspaceScreenPreview.tabs(layout, profile: profile)
    }
    public static let watchedPaths = AgentWorkspaceScreenPreview.watchedPaths
    public static let didChange = AgentWorkspaceScreenPreview.didChange

    public static func glance(dataRoot: URL, scope: String) async -> String? {
        await AgentWorkspacePorts.$binding.withValue(ChatWorkspaceBinding.ports) {
            await AgentWorkspaceScreenPreview.glance(dataRoot: dataRoot, scope: scope)
        }
    }

    public static func render(_ room: String, dataRoot: URL, scope: String) async -> String {
        await AgentWorkspacePorts.$binding.withValue(ChatWorkspaceBinding.ports) {
            await AgentWorkspaceScreenPreview.render(room, dataRoot: dataRoot, scope: scope)
        }
    }
    /// The pane for one tab, exactly as shown; app_page_read page=agent reads this.
    @MainActor
    public static func paneText(_ room: String, root: URL, scope: String) async -> String {
        let said = await HerScreenPreview.glance(dataRoot: root, scope: scope)
        let text = await HerScreenPreview.render(room, dataRoot: root, scope: scope)
        return (said ?? "(no glance this turn)") + "\n\n" + text
    }
}
