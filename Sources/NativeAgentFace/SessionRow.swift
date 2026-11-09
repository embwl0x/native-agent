import SwiftUI
import Foundation

// Blueprint: | `SessionRow.swift` | `SessionRenameRow`, `ChatRenameStateMachine`: exactly-once rename settlement |

/// Disappearance cancels; Escape followed by focus loss must still emit only one terminal rename event.
struct ChatRenameStateMachine: Equatable {
    enum EndResult: Equatable {
        case ignored
        case cancelled
        case committed(String)
    }

    var draftTitle = ""
    private(set) var isRenaming = false
    private var ended = false

    mutating func begin(title: String) {
        draftTitle = title
        isRenaming = true
        ended = false
    }

    mutating func submit(currentTitle: String) -> EndResult {
        let cleaned = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != currentTitle else { return finish(.cancelled) }
        return finish(.committed(cleaned))
    }

    mutating func cancel() -> EndResult {
        finish(.cancelled)
    }

    mutating func focusChanged(isFocused: Bool, currentTitle: String) -> EndResult {
        guard !isFocused, isRenaming else { return .ignored }
        return submit(currentTitle: currentTitle)
    }

    private mutating func finish(_ result: EndResult) -> EndResult {
        guard !ended else { return .ignored }
        ended = true
        isRenaming = false
        return result
    }
}

/// Submit, focus loss and cancellation share one settlement for the person's edit.
struct SessionRenameRow: View {
    let sessionID: String
    let title: String
    let onRenameEnd: (String?) -> Void
    @State private var renameState = ChatRenameStateMachine()
    @FocusState private var titleFocused: Bool

    var body: some View {
        TextField("Session", text: $renameState.draftTitle)
            .textFieldStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .focused($titleFocused)
            .accessibilityIdentifier("chat.sidebar.session.rename.\(sessionID)")
            .onSubmit { endRename(renameState.submit(currentTitle: title)) }
            .onKeyPress(.escape) {
                endRename(renameState.cancel())
                return .handled
            }
            .onExitCommand { endRename(renameState.cancel()) }
            .onChange(of: titleFocused) { _, focused in
                endRename(renameState.focusChanged(isFocused: focused, currentTitle: title))
            }
            .onAppear {
                renameState.begin(title: title)
                DispatchQueue.main.async { titleFocused = true }
            }
            .onDisappear { endRename(renameState.cancel()) }
    }

    private func endRename(_ result: ChatRenameStateMachine.EndResult) {
        switch result {
        case .ignored: return
        case .cancelled: onRenameEnd(nil)
        case .committed(let title): onRenameEnd(title)
        }
    }
}
