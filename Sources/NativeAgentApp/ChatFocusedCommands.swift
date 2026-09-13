import SwiftUI

/// Window-focused chat actions keep keyboard shortcuts out of invisible
/// production buttons. The active main or detached chat window owns the
/// closures; the app command menu only invokes that focused owner.
struct ChatFocusedCommandActions {
    let send: () -> Void
    let attach: () -> Void
    let toggleVoice: () -> Void
    let focusComposer: () -> Void
    let focusTranscriptSearch: () -> Void
    let findNext: () -> Void
    let findPrevious: () -> Void
}

private struct ChatFocusedCommandActionsKey: FocusedValueKey {
    typealias Value = ChatFocusedCommandActions
}

extension FocusedValues {
    var chatCommandActions: ChatFocusedCommandActions? {
        get { self[ChatFocusedCommandActionsKey.self] }
        set { self[ChatFocusedCommandActionsKey.self] = newValue }
    }
}

struct ChatFocusedCommands: Commands {
    @FocusedValue(\.chatCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Chat") {
            Button("Send Message", action: { actions?.send() })
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions == nil)
            Button("Add Attachment…", action: { actions?.attach() })
                .keyboardShortcut("i", modifiers: .command)
                .disabled(actions == nil)
            Button("Toggle Voice Input", action: { actions?.toggleVoice() })
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Focus Composer", action: { actions?.focusComposer() })
                .keyboardShortcut("l", modifiers: .command)
                .disabled(actions == nil)
            Divider()
            Button("Find in Conversation…", action: { actions?.focusTranscriptSearch() })
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button("Find Next", action: { actions?.findNext() })
                .keyboardShortcut("g", modifiers: .command)
                .disabled(actions == nil)
            Button("Find Previous", action: { actions?.findPrevious() })
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}

/// Whether the Chat page is the one the window is actually showing.
///
/// Chat stays MOUNTED behind the page switch for speed (ContentView, 2026-09-13),
/// so `onDisappear` no longer fires when the user leaves it and a hidden
/// ChatView is still a live view with live state. Nothing in a hidden chat may
/// act: this is the one signal that says so. Default `true` — a ChatView that
/// is the whole window (the detached panel, previews, tests) is visible.
private struct ChatPageIsVisibleKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var chatPageIsVisible: Bool {
        get { self[ChatPageIsVisibleKey.self] }
        set { self[ChatPageIsVisibleKey.self] = newValue }
    }
}
