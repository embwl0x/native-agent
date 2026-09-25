import SwiftUI
import ChatOrchestration
import PersistenceCore

/// Agent view (her-screen Phase 8, User 2026-09-23: "I want to see her view"):
/// the glance line and her home or any room on it, exactly the text she
/// receives, read-only in a monospace pane. HerScreenPreview reads without
/// looking (nothing marked seen, nothing written) and never runs a tool; the
/// pane re-reads only on a tab switch or when her world's files change.
struct AgentScreenView: View {
    private struct Watch: Equatable { let root: URL; let scope: String; let room: String }

    @Environment(AppModel.self) private var appModel
    @State private var room = "home"
    @State private var pane = ""

    private var root: URL { appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    var body: some View {
        let scope = appModel.activeChatSessionId
        ShellFrame(classic: false) {
            EmptyView()
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(HerScreenPreview.tabs, id: \.self) { name in
                            let selected = room == name
                            Button { room = name } label: {
                                Text(name)
                                    .font(ShellType.captionMedium)
                                    .foregroundStyle(selected ? NativeAgentShell.text : NativeAgentShell.secondary)
                                    .padding(.horizontal, 10)
                                    .frame(height: 20)
                                    .background { if selected { Capsule().fill(NativeAgentShell.softFill) } }
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
                ScrollView {
                    Text(pane)
                        .font(.system(size: ShellType.captionSize, design: .monospaced))
                        .foregroundStyle(NativeAgentShell.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(AliveMetrics.rowInsetH)
                }
                .aliveCard()
            }
            .padding(.top, 36)
            .padding([.horizontal, .bottom], 20)
        }
        .task(id: Watch(root: root, scope: scope, room: room)) {
            let root = root, room = room
            await ViewFileRefreshTask.run(paths: HerScreenPreview.watchedPaths.map { root.appendingPathComponent($0) }) {
                pane = await Self.paneText(room, root: root, scope: scope)
            }
        }
    }

    static var tabs: [String] { HerScreenPreview.tabs }

    /// The pane for one tab, exactly as shown; app_page_read page=agent reads this.
    static func paneText(_ room: String, root: URL, scope: String) async -> String {
        let said = await HerScreenPreview.glance(dataRoot: root, scope: scope)
        let text = await HerScreenPreview.render(room, dataRoot: root, scope: scope)
        return (said ?? "(no glance this turn)") + "\n\n" + text
    }
}
