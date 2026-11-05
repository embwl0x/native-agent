import Foundation
import SwiftUI
// Blueprint: | `ChatComposerDraft.swift` | `ChatComposerDraft`: Session-owned draft shared by composers |

/// Share one AppModel-owned draft per session; only text readers observe keystrokes so the registry stays quiet.
@MainActor
@Observable
final class ChatComposerDraft {
    var text = ""
    let sessionId: String
    var editedAt = Date.distantPast
    private(set) var manualEditRevision: UInt64 = 0

    init(sessionId: String) { self.sessionId = sessionId }

    /// Either composer must write the same draft object.
    func edit(_ newText: String) {
        manualEditRevision &+= 1
        text = newText
        editedAt = Date()
    }

    /// Dictation must not claim a manual edit; typing invalidates all later updates from that dictation.
    func dictate(_ newText: String, revision: UInt64) {
        guard manualEditRevision == revision else { return }
        text = newText
        editedAt = Date()
    }

    /// Bind directly to the draft child so writes do not invalidate ChatView state.
    var textBinding: Binding<String> {
        Binding(get: { self.text }, set: { self.edit($0) })
    }
}
