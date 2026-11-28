import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `ChatShellViews.swift` | Shared header, conversation slot rows, title selections and row-local relative age |

// MARK: - The header: the agent's name and one dot

struct ShellRoomHeader: View {
    var name: String
    /// The dot reports waits and failures; only the composer states settled trust.
    var status: ChatShellStatus
    var onNewChat: (() -> Void)? = nil
    var notes: InboxNotesCapsule? = nil
    var work: WorkPaneHeaderButton? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(ShellType.columnTitle)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            if let onNewChat {
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(ShellType.bodyMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New chat")
                .accessibilityLabel("New chat")
            }

            Spacer(minLength: 12)

            // Keep transcript search in Find in Conversation so the header has one role.

            work

            notes

            if status != .settled {
                Group {
                    if status.opensTrust {
                        Button {
                            SettingsLink.open(.trust)
                        } label: {
                            statusLabel.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Review permissions in Trust")
                        .accessibilityLabel("\(status.text). Open Trust")
                    } else {
                        statusLabel
                    }
                }
                .accessibilityIdentifier("chat.shell.status-dot")
                .padding(.leading, 4)
            }
        }
        .frame(minHeight: NativeAgentShellLayout.columnHeaderMinHeight)
        // Align header, transcript and composer to one column and gutter.
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .frame(maxWidth: NativeAgentShellLayout.roomColumn, alignment: .topLeading)
        .padding(.leading, NativeAgentShellLayout.roomLeadingInset)
        .padding(.trailing, NativeAgentShellLayout.roomTrailingInset)
        .frame(maxWidth: .infinity, alignment: NativeAgentShellLayout.roomAlignment)
        .padding(.top, NativeAgentShellLayout.columnHeaderTopInset)
        .padding(.bottom, 4)
    }

    private var statusLabel: some View {
        HStack(spacing: 8) {
            Circle().fill(status.color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(status.text).font(ShellType.label).foregroundStyle(NativeAgentShell.secondary).lineLimit(1)
        }
    }
}

// MARK: - The conversations column

struct ShellConversationRow: View {
    var face: SessionRowFace
    var selected: Bool
    /// Show pin controls only while hovered or pinned to keep ordinary rows quiet.
    var onTogglePin: () -> Void = {}

    @State private var hovering = false
    @FocusState private var pinFocused: Bool

    var body: some View {
        // Native List owns selection; rows only display their content.
        let title = face.title
        let pinned = face.isPinned == true
        let pinsKnown = face.isPinned != nil
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .truncationMode(.tail)
            // Use previews to distinguish conversations without rewriting their titles.
            let preview = face.preview
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if !preview.isEmpty {
                    Text(preview)
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: NativeAgentSpacing.sm)
                        .layoutPriority(-1)
                }
                SessionRowAge(date: face.date, surface: face.surface)
                    .font(preview.isEmpty ? ShellType.labelMedium : ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
            }
            if let issue = face.issue {
                Text(issue).font(ShellType.caption).foregroundStyle(NativeAgentShell.trouble)
                    .lineLimit(2).help(issue)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .padding(.trailing, 26)
        .frame(maxWidth: .infinity, minHeight: NativeAgentShellLayout.listRowHeight, alignment: .leading)
        .overlay(alignment: .trailing) {
            Button(action: onTogglePin) {
                Image(systemName: pinsKnown ? (pinned ? "pin.fill" : "pin") : "questionmark.circle")
                    .font(ShellType.labelMedium)
                    .foregroundStyle(pinned ? NativeAgentShell.text : NativeAgentShell.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($pinFocused)
            .opacity(pinned || !pinsKnown || hovering || pinFocused ? 1 : 0)
            .allowsHitTesting(pinsKnown && (pinned || hovering || pinFocused))
            .disabled(!pinsKnown)
            .help(pinsKnown ? (pinned ? "Unpin" : "Pin to the top") : "Pinned conversations have not been read; see the list's read notice")
            .accessibilityLabel(pinsKnown ? (pinned ? "Unpin conversation" : "Pin conversation to the top") : "Pins unavailable")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .accessibilityElement(children: .contain)
    }
}
/// Each mounted row observes only its conversation; the containing list owns identities.
struct ShellSessionFaceRow: View, Equatable {
    @Environment(AppModel.self) private var appModel
    let sessionID: String
    let selected: Bool
    let renaming: Bool
    let quietSelection: Bool
    let onPin: () -> Void
    let onUnpin: () -> Void
    let onRenameBegin: () -> Void
    let onRenameEnd: (String?) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Actions are fixed by session identity; parent list movement changes no row input.
        lhs.sessionID == rhs.sessionID && lhs.selected == rhs.selected && lhs.renaming == rhs.renaming
            && lhs.quietSelection == rhs.quietSelection
    }

    var body: some View {
        let face = appModel.face.slot(.session(sessionID)).value(as: SessionRowFace.self)
        if let face, face.isPresent {
            Group {
                if renaming {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if face.isPinned == true {
                                Button(action: onUnpin) { Image(systemName: "pin.fill") }.buttonStyle(.plain).help("Unpin session")
                            } else if face.isPinned == nil {
                                Text("Pins unread").font(ShellType.caption)
                            }
                            SessionRenameRow(sessionID: sessionID, title: face.title, onRenameEnd: onRenameEnd)
                        }
                        HStack {
                            Text(face.preview)
                            SessionRowAge(date: face.date, surface: face.surface)
                        }
                        .font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary).lineLimit(1)
                    }
                } else {
                    ShellConversationRow(face: face, selected: selected,
                        onTogglePin: {
                            if face.isPinned == true { onUnpin() }
                            else if face.isPinned == false { onPin() }
                        })
                }
            }
            .overlay(alignment: .leading) {
                if face.isUnread {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: -7)
                        .accessibilityLabel("Unread messages")
                }
            }
            .overlay(alignment: .trailing) {
                if face.isRunning {
                    Image(systemName: "ellipsis").font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary).offset(x: 5)
                        .accessibilityLabel("Running")
                }
            }
            .overlay {
                if !renaming { SessionDragSource(sessionId: sessionID, sessionTitle: face.title) }
            }
            .contextMenu {
                if face.isPinned == true { Button("Unpin Tab", systemImage: "pin.slash", action: onUnpin) }
                else if face.isPinned == false { Button("Pin as Tab", systemImage: "pin", action: onPin) }
                else { Text("Pinned conversations unavailable") }
                Button("Rename Chat", systemImage: "pencil", action: onRenameBegin)
                Divider()
                DetachedSessionMenu(sessionID: sessionID)
            }
            .listRowBackground(quietSelection
                ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor)).padding(.horizontal, 10)
                : nil)
            .help("\(face.title)\n\nRight-click to rename, pin, or detach")
        } else {
            Text(face == nil ? "Waiting on this conversation…" : "Conversation removed")
                .font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
        }
    }
}

/// A minute redraw changes only age text; the engine posts dates only when the conversation changes.
private struct SessionRowAge: View {
    let date: Date?
    let surface: String

    @MainActor
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let timeText = date.map { age($0, at: context.date) } ?? "No time"
            if !surface.isEmpty, surface != "Mac" {
                ViewThatFits(in: .horizontal) {
                    Text("\(surface) · \(timeText)")
                        .fixedSize()
                    Text(surface)
                        .fixedSize()
                    Text(surface)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(surface), \(timeText)")
            } else {
                Text(timeText)
                    .fixedSize()
            }
        }
    }

    private func age(_ date: Date, at now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "now" }
        return Self.formatter.localizedString(for: date, relativeTo: now)
    }
}

struct SessionTitleLabel: View {
    @Environment(AppModel.self) private var appModel
    let sessionID: String

    var body: some View {
        Text(appModel.face.slot(.session(sessionID)).select("titleLabel", as: SessionRowFace.self) {
            guard let row = $0 else { return "Waiting on this conversation…" }
            return row.isPresent ? row.title : "Conversation removed"
        })
    }
}

struct SessionListEmptyNotice: View {
    @Environment(AppModel.self) private var appModel
    let searchQuery: String

    var body: some View {
        let loaded = appModel.face.slot(.sessionNavigation).select("indexLoaded", as: SessionNavigationFace.self) { $0?.hasLoadedIndex == true }
        let count = appModel.face.slot(.sessions).select("totalCount", as: SessionListFace.self) { $0?.allIDs.count }
        Group {
            if loaded, let count {
                Text(ChatSessionListEmptyStatePresentation.message(totalSessionCount: count, searchQuery: searchQuery))
            } else {
                Text("Waiting on the conversation list…")
            }
        }
        .font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
    }
}

// MARK: - The empty room

struct ShellEmptyRoom: View {
    var personaName: String
    var onSuggestion: (String) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(ChatShellCopy.greetingTitle(personaName))
                .font(ShellType.display)
                .foregroundStyle(NativeAgentShell.text)
            Text(ChatShellCopy.greetingDetail)
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips }
                VStack(spacing: 8) { chips }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var chips: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ForEach(ChatShellCopy.greetingChips, id: \.self) { chip in
            Button {
                onSuggestion(chip)
            } label: {
                Text(chip)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(TodayPalette.cardFill, in: shape)
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(TodayPalette.cardStroke, lineWidth: 1).allowsHitTesting(false) }
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .help("Start with: \(chip)")
        }
    }
}
