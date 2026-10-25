import SwiftUI
import ChatTurnRuntime
import AppToolRuntime

// Blueprint: | `AgentScreenView.swift` | `AgentScreenView`: read-only agent home/room projection; preview never marks seen, writes or dispatches tools |

/// Agent view (her-screen Phase 8, User 2026-09-23: "I want to see her view"):
/// the glance line and her home or any room on it, exactly the text she
/// receives, read-only in a monospace pane. HerScreenPreview reads without
/// looking (nothing marked seen, nothing written) and never runs a tool; the
/// engine projection re-reads on a tab switch or when her world's files change.
struct AgentScreenView: View {
    private struct Watch: Equatable { let scope: String; let room: String }

    @Environment(AppModel.self) private var appModel
    @Binding var room: String

    var body: some View {
        let scope = appModel.activeChatSessionId
        ShellFrame {
            // Every room in the Mac's own sidebar list (User 09-27: all
            // controls native), so none hides past the window's edge the way
            // the old capsule strip let them.
            List(HerScreenPreview.tabs(appModel.engine.layout.layout, profile: SimpleViewMode.agent), id: \.self,
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
                    Text(appModel.engine.turns.agentScreenPanes[scope]?[room] ?? "")
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
        .task(id: Watch(scope: scope, room: room)) {
            await appModel.engine.turns.observeAgentScreen(room: room, scope: scope)
        }
        .onDisappear { room = "home" }
    }

}
