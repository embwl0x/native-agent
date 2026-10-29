import SwiftUI
import AppKit
import NativeAgentShared
import PersistenceCore

// Blueprint: | `SessionRow.swift` | `SessionRow` and `ChatRenameStateMachine`: session pin/source presentation and one terminal rename result across submit/cancel/focus loss |

/// Shared state transitions for the conversation-row rename editor.
/// A structural disappearance is always a cancel, and only one terminal event
/// may escape even when Escape is immediately followed by focus loss.
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

/// Session-level origin is a trust boundary. Unlike a message's origin, this
/// follows the whole conversation in the sidebar, so never interpolate a raw
/// stored value or silently hide a missing one.
struct ChatSidebarSessionSourceBadge: Equatable {
    enum Tone: Equatable {
        case remote
        case unknown
    }

    let label: String
    let symbol: String
    let tone: Tone

    static func make(source: String?) -> Self? {
        guard let raw = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return Self(label: "Unknown origin", symbol: "questionmark.circle", tone: .unknown)
        }

        switch raw.lowercased() {
        case "app":
            return nil
        case "telegram":
            return Self(label: "Telegram", symbol: "paperplane.fill", tone: .remote)
        case "ios", "iphone", "ipad":
            return Self(label: "iPhone / iPad", symbol: "iphone", tone: .remote)
        case "slack":
            return Self(label: "Slack", symbol: "bubble.left.and.bubble.right.fill", tone: .remote)
        case "bridge", "agent_bridge":
            return Self(label: "Bridge", symbol: "arrow.left.arrow.right", tone: .remote)
        default:
            return Self(label: "External source", symbol: "exclamationmark.triangle", tone: .unknown)
        }
    }
}

// Rows omit previews but search includes them; rename matches PinnedSessionTab's commit/cancel behavior.
struct SessionRow: View {
    enum PinState {
        case unpinned
        case pinned(onUnpin: () -> Void)

        var isPinned: Bool {
            if case .pinned = self { return true }
            return false
        }

        func performUnpin() {
            guard case let .pinned(onUnpin) = self else { return }
            onUnpin()
        }
    }

    var session: ChatSession
    var selected: Bool
    var pinState: PinState
    var onSelect: () -> Void
    var renaming: Bool = false
    var onRenameBegin: (() -> Void)? = nil
    /// nil = rename canceled/no-op; non-nil = commit this cleaned title.
    var onRenameEnd: ((String?) -> Void)? = nil

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var renameState = ChatRenameStateMachine()
    @FocusState private var titleFocused: Bool
    // One rename ends exactly once. Esc fires onExitCommand AND the resulting
    // focus loss fires the onChange commit before the parent's renaming=false
    // re-render lands — without this guard a canceled edit could still
    // commit. (PinnedSessionTab gets this for free from its local isRenaming;
    // this row's rename state lives in the parent, so the sync guard is local.)

    var body: some View {
        HStack(spacing: 6) {
            if pinState.isPinned {
                Button(action: pinState.performUnpin) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Unpin session")
                .accessibilityLabel("Unpin session")
            }
            titleView
            Spacer(minLength: 4)
            // The hover pencil reserves its slot and avoids delaying selection with double-click detection.
            if onRenameBegin != nil {
                let pencilVisible = hovering && !renaming
                Button {
                    onRenameBegin?()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 14)
                .opacity(pencilVisible ? 1 : 0)
                .allowsHitTesting(pencilVisible)
                .help("Rename session")
                .accessibilityLabel("Rename session")
                .accessibilityIdentifier("chat.sidebar.session.rename-pencil.\(session.id)")
                .accessibilityHidden(!pencilVisible)
            }
            if let sourceBadge = ChatSidebarSessionSourceBadge.make(source: session.source) {
                Label(sourceBadge.label, systemImage: sourceBadge.symbol)
                    .font(.caption2)
                    .foregroundStyle(sourceBadge.tone == .remote ? Color.orange : Color.red)
                    .lineLimit(1)
                    .accessibilityLabel("Session origin: \(sourceBadge.label)")
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            // Hover fills unselected rows with Reduce Motion-aware animation.
            RoundedRectangle(cornerRadius: 8)
                .fill(selected
                    ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                    : AnyShapeStyle(Color.primary.opacity(hovering ? 0.07 : 0)))
        }
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion),
            value: hovering
        )
        .onHover { hovering = $0 }
        // LazyVStack recycles rows by identity — clear hover on disappear so a
        // recycled row can't reappear pre-lit with the rename pencil showing.
        .onDisappear { hovering = false }
    }

    @ViewBuilder
    private var titleView: some View {
        if renaming {
            TextField("Session", text: $renameState.draftTitle)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .focused($titleFocused)
                .onSubmit { endRename(renameState.submit(currentTitle: session.displayTitle)) }
                // Submit or genuine focus loss commits; Escape, selection changes
                // and structural disappearance cancel through the single-fire state machine.
                .onKeyPress(.escape) {
                    endRename(renameState.cancel())
                    return .handled
                }
                .onExitCommand { endRename(renameState.cancel()) }
                .onChange(of: titleFocused) { _, focused in
                    endRename(renameState.focusChanged(
                        isFocused: focused,
                        currentTitle: session.displayTitle
                    ))
                }
                .onAppear {
                    renameState.begin(title: session.displayTitle)
                    DispatchQueue.main.async { titleFocused = true }
                }
                .onDisappear { endRename(renameState.cancel()) }
        } else {
            Text(session.displayTitle)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                // Keep the drag source and pointer hit-testing unchanged,
                // but expose the same selection action to VoiceOver.
                .accessibilityLabel(session.displayTitle)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(selected ? "Selected" : "Not selected")
                .accessibilityHint("Opens this conversation")
                .accessibilityAction { onSelect() }
        }
    }

    private func endRename(_ result: ChatRenameStateMachine.EndResult) {
        switch result {
        case .ignored:
            return
        case .cancelled:
            onRenameEnd?(nil)
        case .committed(let title):
            onRenameEnd?(title)
        }
    }
}
