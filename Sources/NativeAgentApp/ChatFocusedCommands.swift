import SwiftUI

// Blueprint: | `ChatFocusedCommands.swift` | `ChatFocusedCommands`: active-window chat action closures and page visibility, keeping shortcuts out of hidden controls |

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

/// Hidden mounted chats cannot act; standalone chats are visible by default.
private struct ChatPageIsVisibleKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var chatPageIsVisible: Bool {
        get { self[ChatPageIsVisibleKey.self] }
        set { self[ChatPageIsVisibleKey.self] = newValue }
    }
}
