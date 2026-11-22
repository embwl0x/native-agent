import Foundation
import SwiftUI
// Blueprint: | `ChatComposerDraft.swift` | `ChatComposerDraft`: Session-owned draft shared by composers |

/// Share one AppModel-owned draft per session; Send observes availability rather than every character.
@MainActor
@Observable
final class ChatComposerDraft {
    private(set) var text = ""
    private(set) var hasVisibleText = false
    /// Counts manual edits; the quiet composer reads it to tell a typed draft from a carried one.
    private(set) var manualEditRevision: UInt64 = 0
    let sessionId: String
    var editedAt = Date.distantPast

    init(sessionId: String) { self.sessionId = sessionId }

    /// Either composer must write the same draft object.
    func edit(_ newText: String) {
        manualEditRevision &+= 1
        replaceText(newText)
        editedAt = Date()
    }

    private func replaceText(_ newText: String) {
        guard text != newText else { return }
        text = newText
        let visible = newText.contains { !$0.isWhitespace }
        if hasVisibleText != visible { hasVisibleText = visible }
    }
}
