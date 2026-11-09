import Foundation
import SwiftUI
// Blueprint: | `ChatComposerDraft.swift` | `ChatComposerDraft`: Session-owned draft shared by composers |

/// Share one AppModel-owned draft per session; Send observes availability rather than every character.
@MainActor
@Observable
final class ChatComposerDraft {
    private(set) var text = ""
    private(set) var hasVisibleText = false
    let sessionId: String
    var editedAt = Date.distantPast
    private(set) var manualEditRevision: UInt64 = 0

    init(sessionId: String) { self.sessionId = sessionId }

    /// Either composer must write the same draft object.
    func edit(_ newText: String) {
        guard text != newText else { return }
        if manualEditRevision == .max { manualEditRevision = 0 }
        else { manualEditRevision += 1 }
        replaceText(newText)
        editedAt = Date()
    }

    /// Dictation must not claim a manual edit; typing invalidates all later updates from that dictation.
    func dictate(_ newText: String, revision: UInt64) {
        guard manualEditRevision == revision else { return }
        replaceText(newText)
        editedAt = Date()
    }

    private func replaceText(_ newText: String) {
        guard text != newText else { return }
        text = newText
        let visible = ChatTranscriptPresentation.hasVisibleText(newText)
        if hasVisibleText != visible { hasVisibleText = visible }
    }

    /// Bind directly to the draft child so writes do not invalidate ChatView state.
    var textBinding: Binding<String> {
        Binding(get: { self.text }, set: { self.edit($0) })
    }
}
