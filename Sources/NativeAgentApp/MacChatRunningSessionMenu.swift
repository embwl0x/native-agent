import EngineRuntime
import SwiftUI
import NativeAgentShared

// Blueprint: | `MacChatRunningSessionMenu.swift` | `MacChatRunningSessionMenu`: shared go-to menu for sessions with background turns |

/// Keep the menu outside ChatView.body to stay within Swift's type-checker complexity limit.
struct MacChatRunningSessionMenu: View {
    let routes: [MacChatRunningSessionRoute]
    let onSelect: (String) -> Void

    var body: some View {
        Menu("Go to\u{2026}") {
            ForEach(routes, id: \.sessionId) { route in
                Button(route.title) { onSelect(route.sessionId) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
