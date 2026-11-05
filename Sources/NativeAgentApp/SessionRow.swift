import SwiftUI
import AppKit
import NativeAgentShared
import PersistenceCore

// Blueprint: | `SessionRow.swift` | `SessionRow`, `ChatRenameStateMachine`: pin/origin display; exactly-once rename settlement |

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

/// Session origin is a trust boundary; never interpolate raw stored values or hide a missing one.
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
        case "ios":
            return Self(label: "iPhone / iPad", symbol: "iphone", tone: .remote)
        case "slack":
            return Self(label: "Slack", symbol: "bubble.left.and.bubble.right.fill", tone: .remote)
        case "agent-bridge":
            return Self(label: "Bridge", symbol: "arrow.left.arrow.right", tone: .remote)
        default:
            return Self(label: "External source", symbol: "exclamationmark.triangle", tone: .unknown)
        }
    }
}

// Search includes omitted previews so compact rows do not reduce discoverability.
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
    /// Nil is cancellation or no-op; only a non-nil cleaned title commits.
    var onRenameEnd: ((String?) -> Void)? = nil

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var renameState = ChatRenameStateMachine()
    @FocusState private var titleFocused: Bool
    // Escape triggers focus loss before the parent redraws; a local guard prevents a canceled rename from committing.

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
        // LazyVStack recycles rows; clear hover so a reused row cannot reappear pre-lit.
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
                // Route submit, focus loss and cancellation through one state machine to prevent duplicate settlement.
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
                // Expose selection to VoiceOver without changing drag or pointer hit-testing.
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
