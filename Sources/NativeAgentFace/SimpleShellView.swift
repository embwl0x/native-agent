import SwiftUI
import NativeAgentShared
// Blueprint: | `SimpleShellView.swift` | Simple's local selection draws contact and helper slots without owning either catalog |

extension EnvironmentValues {
    @Entry var simpleSettingsMenuDrawnOpen = false
}

struct SimpleShellView: View {
    enum Pane: Hashable { case agent, contact(String), helper(String) }
    @Environment(AppModel.self) private var appModel
    @State private var pane: Pane = .agent

    var body: some View {
        ShellFrame {
            SimpleSidebar(pane: $pane)
        } detail: {
            let showingChat = pane == .agent
            ZStack {
                ChatView()
                    .environment(\.chatPageIsVisible, showingChat)
                    .opacity(showingChat ? 1 : 0)
                    .allowsHitTesting(showingChat)
                    .disabled(!showingChat)
                    .accessibilityHidden(!showingChat)
                    .accessibilityElement(children: showingChat ? .contain : .ignore)
                switch pane {
                case .agent: EmptyView()
                case .contact(let id): SimpleContactThread(contactID: id) { pane = .agent }.id(id)
                case .helper(let id): SimpleHelperRuns(helperID: id) { pane = .agent }.id(id)
                }
            }
        }
        .faceObservation(.key(.contacts))
        .faceObservation(.key(.helpers))
        .environment(\.layoutProfile, SimpleViewMode.simple)
    }
}
