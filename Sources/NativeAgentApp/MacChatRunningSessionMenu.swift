import SwiftUI
import NativeAgentShared

/// 658.14 — "Go to…" for the sessions running a turn in the background.
///
/// Lives in its own file rather than inline in ChatView for a mechanical
/// reason: ChatView's body is already at the Swift type-checker's limit, and
/// adding a Menu + ForEach inline pushed it over ("unable to type-check this
/// expression in reasonable time"). Extraction is the fix that SwiftUI godfiles
/// require; it also gives the routing its own testable seam.
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
