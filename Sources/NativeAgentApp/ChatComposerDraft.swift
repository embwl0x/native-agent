import Foundation
import SwiftUI
// Blueprint: | `ChatComposerDraft.swift` | `ChatComposerDraft`: the shared session text, edit timestamp and manual-edit revision for dictation; AppModel owns its lifetime and composers bind to the same object |

/// One live draft per session, owned by AppModel and shared by its composers.
/// Only views reading text observe keystrokes; the registry is unobserved.
@MainActor
@Observable
final class ChatComposerDraft {
    var text = ""
    let sessionId: String
    var editedAt = Date.distantPast
    private(set) var manualEditRevision: UInt64 = 0

    init(sessionId: String) { self.sessionId = sessionId }

    /// Typing in either composer changes the same object.
    func edit(_ newText: String) {
        manualEditRevision &+= 1
        text = newText
        editedAt = Date()
    }

    /// Dictation advances its own text without claiming a manual edit.
    /// Once typing intervenes, every later update from that dictation is stale.
    func dictate(_ newText: String, revision: UInt64) {
        guard manualEditRevision == revision else { return }
        text = newText
        editedAt = Date()
    }

    /// The binding the text field writes through. Handed to the composer child
    /// view so the write lands on this object and not on `ChatView`'s state.
    var textBinding: Binding<String> {
        Binding(get: { self.text }, set: { self.edit($0) })
    }
}
