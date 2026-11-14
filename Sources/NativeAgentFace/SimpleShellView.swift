import SwiftUI
import NativeAgentShared
// Blueprint: | `SimpleShellView.swift` | Simple's local selection draws contact and helper slots beside chat; every other page shows in place |

/// Simple: the agent's card, the places and the folded Agents and Helpers lists beside one chat. Chat holds the conversation and the agents'
/// and helpers' threads; every other place shows its tabs and pages in place, as Advanced does, and the view stays Simple.
struct SimpleShellView: View {
    enum Pane: Hashable { case agent, contact(String), helper(String) }
    @Environment(AppModel.self) private var appModel
    @State private var pane: Pane = .agent
    /// The page the window shows.
    let shown: ShellRailRow
    /// Choosing a place, with the pages the layout shows of it.
    let choose: (ShellSurface, [ShellRailRow]) -> Void
    /// Selecting one page: a place's tab, or Chat when a thread or the conversation opens.
    let select: (ShellRailRow) -> Void

    var body: some View {
        let inChat = shown == .item(.chat)
        ShellFrame {
            SimpleSidebar(pane: $pane, shown: shown, choose: choose, select: select)
        } detail: {
            let showingChat = inChat && pane == .agent
            ZStack {
                ChatView()
                    .environment(\.chatPageIsVisible, showingChat)
                    .opacity(showingChat ? 1 : 0)
                    .allowsHitTesting(showingChat)
                    .disabled(!showingChat)
                    .accessibilityHidden(!showingChat)
                    .accessibilityElement(children: showingChat ? .contain : .ignore)
                if inChat {
                    switch pane {
                    case .agent: EmptyView()
                    case .contact(let id): SimpleContactThread(contactID: id) { pane = .agent }.id(id)
                    case .helper(let id): SimpleHelperRuns(helperID: id) { pane = .agent }.id(id)
                    }
                }
                ShellPlacePage(shown: shown, select: select)
            }
        }
        .faceObservation(.key(.contacts))
        .faceObservation(.key(.helpers))
        .environment(\.layoutProfile, SimpleViewMode.simple)
        // A conversation the window is sent to is shown itself, not hidden under an agent's or helper's thread left open.
        .onChange(of: appModel.activeChatSessionId) { _, _ in pane = .agent }
    }
}
