import AgentWorkspace
import Foundation

/// Binds the conversation and tool owners for the app's read-only screen door.
public enum HerScreenPreview {
    public static let tabs = AgentWorkspaceScreenPreview.tabs
    public static let watchedPaths = AgentWorkspaceScreenPreview.watchedPaths

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
}
