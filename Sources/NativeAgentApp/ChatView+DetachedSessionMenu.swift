import SwiftUI

extension ChatView {
    @ViewBuilder
    func detachedSessionMenu(sessionID: String) -> some View {
        if DetachedChatWindowController.shared.isDetached(sessionID) {
            Button("Bring Detached Window to Front", systemImage: "macwindow.on.rectangle") {
                DetachedChatWindowController.shared.focus(sessionId: sessionID)
            }
            Button("Close Detached Window", systemImage: "xmark.rectangle") {
                DetachedChatWindowController.shared.close(sessionId: sessionID)
            }
        } else {
            Button("Open in Detached Window", systemImage: "rectangle.badge.plus") {
                DetachedChatWindowController.shared.open(sessionId: sessionID, origin: nil)
            }
        }
    }
}
