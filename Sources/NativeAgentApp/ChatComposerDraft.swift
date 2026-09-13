import Foundation
import SwiftUI

/// The in-progress composer text, lifted out of `ChatView`'s `@State`.
///
/// User, 2026-09-13: typing lagged 1-2s per keystroke. The draft used to be
/// `@State` on `ChatView`, so every character invalidated `ChatView.body` —
/// which re-diffed the whole `[ChatMessage]` (`ChatMessage.==` was the hottest
/// app frame in `/usr/bin/sample`), re-ran every `MessageBubble` body with its
/// per-message bridge-tag string parsing, and rebuilt the conversation list
/// rows (`ChatShellConversationRow.title(for:openingLine:)`), all inside the
/// window's layout pass.
///
/// As an `@Observable` reference type the draft only invalidates the views that
/// actually READ `text` during their own body. `ChatView.body` reads none of
/// these properties (the one place it did — `canSend` — moved into
/// `ChatComposerInput`), so a keystroke now re-runs the composer alone.
///
/// The three bookkeeping fields keep the 2026-09-06 two-composer rules intact:
/// `sessionId` is the conversation the text belongs to, `adoptedText` is what
/// this composer last loaded (an untouched composer must not clobber another
/// surface's draft), and `editedAt` is when it was last changed HERE.
@MainActor
@Observable
final class ChatComposerDraft {
    var text = ""
    var sessionId = ""
    var adoptedText = ""
    var editedAt = Date.distantPast

    /// A local edit: the text changed on THIS surface, so it wins a flush race.
    func edit(_ newText: String) {
        text = newText
        editedAt = Date()
    }

    /// The binding the text field writes through. Handed to the composer child
    /// view so the write lands on this object and not on `ChatView`'s state.
    var textBinding: Binding<String> {
        Binding(get: { self.text }, set: { self.edit($0) })
    }
}
