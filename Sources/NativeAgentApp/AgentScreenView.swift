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
        ShellFrame {
            // Every room in the Mac's own sidebar list (User 09-27: all
            // controls native), so none hides past the window's edge the way
            // the old capsule strip let them.
            List(HerScreenPreview.tabs, id: \.self,
                 selection: Binding<String?>(get: { room }, set: { if let next = $0 { room = next } })) { name in
                Text(name).font(ShellType.label)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 12, for: .scrollContent)
            .padding(.top, NativeAgentShellLayout.titleBarInset)
            .frame(width: 200)
            .overlay(alignment: .trailing) {
                Rectangle().fill(NativeAgentShell.hairline).frame(width: 1).allowsHitTesting(false)
            }
            .accessibilityLabel("Rooms")
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
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
