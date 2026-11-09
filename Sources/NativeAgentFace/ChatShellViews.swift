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
                Button {
                    NotificationCenter.default.post(name: .openCommandRouteRequest, object: "trust")
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                        Text(status.text)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Review permissions in Trust")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(status.text). Open Trust")
                .accessibilityIdentifier("chat.shell.status-dot")
                .padding(.leading, 4)
            }
        }
        // Align header, transcript and composer to one column and gutter.
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .frame(maxWidth: NativeAgentShellLayout.roomColumn, alignment: .topLeading)
        .padding(.leading, NativeAgentShellLayout.roomLeadingInset)
        .padding(.trailing, NativeAgentShellLayout.roomTrailingInset)
        .frame(maxWidth: .infinity, alignment: NativeAgentShellLayout.roomAlignment)
        .padding(.top, NativeAgentShellLayout.columnHeaderTopInset)
        .padding(.bottom, 4)
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
            HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                if !preview.isEmpty {
                    Text(preview)
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
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
        .padding(.trailing, pinned || !pinsKnown ? 26 : 0)
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 3) {
                if surface != "Mac" { Text(surface) }
                if let date {
                    if surface != "Mac" { Text("·") }
                    Text(age(date, at: context.date))
                } else {
                    Text("Time unavailable")
                }
            }
        }
    }

    private func age(_ date: Date, at now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
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

// MARK: - Tool traffic

/// Use one bare disclosure so activity does not add another plate.
struct ChatActivityRow<Leading: View, Detail: View>: View {
    let title: String
    var trailing: String = ""
    @Binding var isExpanded: Bool
    var accessibilityLabel: String? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var detail: () -> Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var indent: CGFloat { 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(NativeAgentMotion.respecting(
                    NativeAgentMotion.arrive, reduceMotion: reduceMotion
                )) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(ShellType.captionSemibold)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    leading()
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if !trailing.isEmpty {
                        Text(trailing)
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.tertiary)
                    }
                }
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .buttonFocusable()
            .shellKeyboardTarget(.receipt)
            .accessibilityLabel(accessibilityLabel ?? title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            VStack(alignment: .leading, spacing: 0) {
                if isExpanded {
                    detail()
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, Self.indent)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(NativeAgentMotion.arrivalFade)
                }
            }
            // Clip transition travel without clipping the moving rows.
            .clipped()
        }
        .padding(.vertical, NativeAgentSpacing.xs)
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
    }
}

extension ChatActivityRow where Leading == EmptyView {
    init(
        title: String,
        trailing: String = "",
        isExpanded: Binding<Bool>,
        accessibilityLabel: String? = nil,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.init(title: title, trailing: trailing, isExpanded: isExpanded,
                  accessibilityLabel: accessibilityLabel,
                  leading: { EmptyView() }, detail: detail)
    }
}

/// Fold the helper reply without exposing its routing envelope.
struct ShellEnvelopeRow: View {
    var title: String
    var content: String
    @State private var expanded = false

    var body: some View {
        ChatActivityRow(title: title, isExpanded: $expanded) {
            Text(content)
        }
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

            HStack(spacing: 8) {
                ForEach(ChatShellCopy.greetingChips, id: \.self) { chip in
                    Button {
                        onSuggestion(chip)
                    } label: {
                        Text(chip)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .houseSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Start with: \(chip)")
                }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Trouble

/// Failure and eligibility arrive together from the body's message presentation.
struct ShellTroubleCard: View {
    var action: MessageActionFace
    var failure: WireFailure
    var showsStuckLink: Bool
    var onRetry: () -> Void
    var onContinue: () -> Void
    var onOpenSettings: () -> Void
    @State private var confirming: WireFailure?
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.message, systemImage: "exclamationmark.circle")
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.trouble)
                .accessibilityIdentifier("chat.shell.trouble-line")
            HStack(spacing: 14) {
                if action.canRetry {
                    Button("Try again…") { confirming = failure }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("chat.shell.trouble-retry")
                }
                if action.canContinue {
                    Button("Continue from here", action: onContinue).buttonStyle(.bordered).controlSize(.small)
                }
                if failure.cause != nil {
                    Button(showsDetails ? "Hide details" : "Details") { showsDetails.toggle() }
                        .buttonStyle(.plain).font(ShellType.label)
                        .accessibilityIdentifier("chat.shell.trouble-details")
                }
                if showsStuckLink {
                    Button(ChatShellCopy.errorStuckLink, action: onOpenSettings).buttonStyle(.plain).font(ShellType.label)
                        .accessibilityIdentifier("chat.shell.stuck-settings-link")
                }
            }
            if showsDetails, let cause = failure.cause {
                Text(cause).font(ShellType.code).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(FailedTurnRetryConfirmation(failure: $confirming, onRetry: onRetry, onContinue: onContinue))
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        .houseSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.shell.trouble-card")
    }
}
