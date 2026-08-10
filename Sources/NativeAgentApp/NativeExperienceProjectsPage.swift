import AppKit
import SwiftUI

struct NativeExperienceProjectsPage: View {
    @Environment(AppModel.self) private var appModel
    let showLineage: Bool
    @State private var spaces: [ExperienceProjectSpace] = []
    @State private var selectedWorkspaceID: String?
    @State private var comparisonTargetID: String?
    @State private var comparison: ExperienceSessionComparison?
    @State private var busy = false

    var body: some View {
        NativeExperiencePage(
            title: "Projects & Sessions",
            subtitle: "Saved workspaces, Git state, Desk evidence, and conversation branches joined without creating project-specific minds or a second transcript store."
        ) {
            NativeExperienceCard(title: "Project Spaces", icon: "folder.badge.gearshape") {
                if spaces.isEmpty {
                    Text("No saved workspaces yet. Add one through the existing workspace owner.").foregroundStyle(.secondary)
                }
                ForEach(spaces) { space in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(space.name, systemImage: "folder") .font(.headline)
                            Spacer()
                            if let branch = space.branch { Text(branch).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: space.path)]) }
                        }
                        Text(space.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 14) {
                            Label(space.gitAvailable ? "Git \(space.head ?? "")" : "Not a Git repository", systemImage: "arrow.triangle.branch")
                            Label("\(space.dirtyFileCount ?? 0) changed", systemImage: "doc.badge.ellipsis")
                            Label("\(space.sessions.count) sessions", systemImage: "bubble.left.and.bubble.right")
                            Label("\(space.workshopExecutions.count) runs", systemImage: "hammer")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if let readError = space.readError { Text(readError).font(.caption).foregroundStyle(.orange) }
                    }
                    Divider()
                }
                HStack {
                    Button("Manage Workspaces") { NativeAgentAppCoordinator.shared.request(.sidebar(.connectors)) }
                    Button("Open Desk") { NativeAgentAppCoordinator.shared.request(.sidebar(.desk)) }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                }
            }

            if showLineage {
                NativeExperienceCard(title: "Conversation lineage", icon: "arrow.triangle.branch") {
                    LabeledContent("Current", value: activeSession?.displayTitle ?? appModel.activeChatSessionId)
                    Picker("Project Space", selection: $selectedWorkspaceID) {
                        Text("No project").tag(String?.none)
                        ForEach(appModel.workspaces) { workspace in
                            Text(workspace.name).tag(Optional(workspace.id))
                        }
                    }
                    .onChange(of: selectedWorkspaceID) { _, id in
                        let workspace = appModel.workspaces.first { $0.id == id }
                        Task { _ = await appModel.associateActiveChat(with: workspace); await refresh() }
                    }
                    HStack {
                        Button("Branch this conversation", systemImage: "arrow.triangle.branch") {
                            Task { busy = true; _ = await appModel.forkActiveChatSession(); busy = false; await refresh() }
                        }
                        .disabled(busy)
                        Button("Export with provenance", systemImage: "square.and.arrow.up") { Task { await exportActive() } }
                        Spacer()
                        Button("Return to Chat") { NativeAgentAppCoordinator.shared.request(.sidebar(.chat)) }
                    }
                    Divider()
                    Picker("Compare current with", selection: $comparisonTargetID) {
                        Text("Choose a session").tag(String?.none)
                        ForEach(appModel.experienceSessionBranches.filter { $0.id != appModel.activeChatSessionId }) { session in
                            Text("\(session.title) · \(compact(session.id))").tag(Optional(session.id))
                        }
                    }
                    .onChange(of: comparisonTargetID) { _, value in
                        guard let value else { comparison = nil; return }
                        Task { comparison = await appModel.compareActiveChat(with: value) }
                    }
                    if let comparison {
                        Grid(alignment: .leading, horizontalSpacing: 20) {
                            GridRow { Text("Shared prefix").foregroundStyle(.secondary); Text("\(comparison.commonMessageCount) messages") }
                            GridRow { Text("Current only").foregroundStyle(.secondary); Text("\(comparison.leftOnly.count) messages") }
                            GridRow { Text("Other only").foregroundStyle(.secondary); Text("\(comparison.rightOnly.count) messages") }
                        }
                    }
                    Text("A branch copies one verified transcript prefix into a new canonical session. The source stays immutable; selected learning enters MemoryV2 only through an explicit retain action.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .task { await refresh() }
    }

    private var activeSession: ChatSession? { appModel.chatSessions.first { $0.id == appModel.activeChatSessionId } }

    @MainActor private func refresh() async {
        await appModel.refreshForSidebarItem(.connectors)
        await appModel.refreshForSidebarItem(.desk)
        spaces = await NativeExperienceReadModels.projectSpaces(
            workspaces: appModel.workspaces,
            sessions: appModel.experienceSessionBranches,
            executions: appModel.executions
        )
        selectedWorkspaceID = activeSession?.projectSpaceId
    }

    @MainActor private func exportActive() async {
        guard let markdown = await appModel.sessionLineageExport(sessionID: appModel.activeChatSessionId) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "conversation-\(appModel.activeChatSessionId.prefix(8)).md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try markdown.write(to: url, atomically: true, encoding: .utf8) }
        catch { appModel.statusText = "Conversation export failed: \(error.localizedDescription)" }
    }

    private func compact(_ id: String) -> String { id.count > 10 ? "\(id.prefix(8))…" : id }
}
