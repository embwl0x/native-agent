import Cognition
import AppToolRuntime
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
            List(Self.tabs, id: \.self,
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
            await EventDeadlinePhysiology.refreshOnChanges(paths: HerScreenPreview.watchedPaths.map { root.appendingPathComponent($0) }) {
                pane = await HerScreenPreview.paneText(room, root: root, scope: scope)
            }
        }
    }

    /// Home, the places the layout shows (ui/layout.json), then home's rooms.
    @MainActor static var tabs: [String] { HerScreenPreview.tabs(SurfaceLayoutLive.shared.layout, profile: SimpleViewMode.agent) }

}
