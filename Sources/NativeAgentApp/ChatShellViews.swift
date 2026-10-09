import SwiftUI
import NativeAgentShared
import TrustCenter

// ui-simplify 2026-09-02 (Lane A): the room's furniture.
//
// Agent's read, against the real screen: "stop building a control panel with a
// chat in it and build a desk with a drawer." These are the pieces that make
// the room a room — one status dot instead of two warning surfaces, a
// conversation list that shows what a conversation was ABOUT, tool traffic as
// one quiet line, and a composer that is obviously the thing.

// MARK: - The header: her name and one dot

struct ShellRoomHeader: View {
    var name: String
    /// The settled posture is the composer's to say (its trust word, wave 3:
    /// once, not in both places); the dot shows when something waits or went
    /// wrong.
    var status: ChatShellStatus
    /// Simple view has no conversations list; this is its one way to start a
    /// fresh thread besides /new (User 09-27). The phone follows the Mac.
    var onNewChat: (() -> Void)? = nil
    /// Fluid glass A2: unread notes as one "N updates" capsule.
    var notes: InboxNotesCapsule? = nil
    /// The Work pane's button, main window only (WorkPane.swift).
    var work: WorkPaneHeaderButton? = nil

    private var isSettled: Bool { if case .settled = status { true } else { false } }

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

            // Agent, 2026-09-02, glyph diet: the magnifier that used to sit
            // here was the room's SECOND search box, next to the one over the
            // conversations list, and neither said which was which. The
            // transcript search kept its own way in — Chat ▸ Find in
            // Conversation… (⌘F) — so this one is simply gone.
            // Conversation controls live beside the draft in the composer.

            work

            notes

            if !isSettled {
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
        // Agent, 2026-09-02: her name used to float at the far left of the
        // pane while the conversation sat in a centred column, so the header
        // belonged to a different room than the words under it. It is now the
        // same 720pt column as the transcript and the composer.
        // Agent, 2026-09-03: the right cluster used to end on the 960 column's
        // edge, 204pt past the last word of every reply, so it floated in a
        // margin attached to nothing. The header now wears the room's gutter
        // inside the room's column, which puts "Agent" on the first character
        // of her replies and the status dot on their last.
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .frame(maxWidth: NativeAgentShellLayout.roomColumn, alignment: .topLeading)
        .padding(.leading, NativeAgentShellLayout.roomLeadingInset)
        .padding(.trailing, NativeAgentShellLayout.roomTrailingInset)
        .frame(maxWidth: .infinity, alignment: NativeAgentShellLayout.roomAlignment)
        // User, 2026-10-04: a slim bar like Claude's, not a band over her chat.
        .padding(.top, NativeAgentShellLayout.columnHeaderTopInset)
        .padding(.bottom, 4)
    }
}

// MARK: - The conversations column

/// One row: a title a person recognises, and where and when it happened.
struct ShellConversationRow: View {
    /// The one id the travelling selection bar is known by.
    static let selectionBarID = "shell.conversations.selection-bar"
    var session: ChatSession
    var selected: Bool
    var isPinned: Bool
    var onSelect: () -> Void
    /// User, 2026-09-02: "a way to pin sessions you want at top." The pin was
    /// only in the right-click menu; now it is on the row, shown when the
    /// row is hovered or already pinned.
    var onTogglePin: () -> Void = {}
    /// Shared with every other row so the selection bar travels, same as the
    /// rail's does.
    var barNamespace: Namespace.ID

    @State private var hovering = false
    @FocusState private var pinFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The native List draws selection and takes the click (User 09-27:
        // all controls Mac native); the row is just its words and the pin.
        let title = ChatShellConversationRow.title(for: session)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .truncationMode(.tail)
            // Wave 3: rows sharing a title ("Codex check-in") are told
            // apart by their last line; the title never changes with it.
            let preview = ChatShellConversationRow.listPreview(for: session, title: title)
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
                Text(ChatShellConversationRow.subtitle(for: session))
                    .font(preview.isEmpty ? ShellType.labelMedium : ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .padding(.trailing, isPinned ? 26 : 0)
        .frame(maxWidth: .infinity, minHeight: NativeAgentShellLayout.listRowHeight, alignment: .leading)
        .overlay(alignment: .trailing) {
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(ShellType.labelMedium)
                    .foregroundStyle(isPinned ? NativeAgentShell.text : NativeAgentShell.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($pinFocused)
            .opacity(isPinned || hovering || pinFocused ? 1 : 0)
            .allowsHitTesting(isPinned || hovering || pinFocused)
            .help(isPinned ? "Unpin" : "Pin to the top")
            .accessibilityLabel(isPinned ? "Unpin conversation" : "Pin conversation to the top")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Tool traffic

/// Fluid glass A2: the transcript's ONE activity row. Tool folds, the live
/// tool line, single tool calls, working notes and worker replies were four
/// styles (an arrow with Show/Hide, a spinner box, a 24pt-indented card in
/// system fonts with a Details label, a small chevron); they are all this
/// now. One chevron that turns, one indent for what opens, the shell's type.
/// It is a hinge, not a card (Agent, 2026-09-03): no fill, no border.
struct ChatActivityRow<Leading: View, Detail: View>: View {
    let title: String
    var trailing: String = ""
    @Binding var isExpanded: Bool
    var accessibilityLabel: String? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var detail: () -> Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where opened detail starts: past the chevron and its gap.
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
            // Clip the transition's travel, not the moving rows themselves.
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

/// A worker's reply, folded: the headline row opens onto the words, and the
/// routing slip it came wrapped in never renders here.
struct ShellEnvelopeRow: View {
    var content: String
    @State private var expanded = false

    var body: some View {
        ChatActivityRow(title: ChatShellEnvelope.headline(content), isExpanded: $expanded) {
            Text(ChatShellEnvelope.reply(content))
        }
    }
}

/// ONE quiet row per turn. Opening it says what she actually touched, in
/// sentences, and each sentence opens onto that call's result.
struct ShellToolRow: View {
    var messages: [ChatMessage]
    @State private var expanded = false

    /// Only a recorded FALSE is a failure; most rows record no outcome at all
    /// (2026-09-06, same rule the detail lines use). 2026-09-14: a row that
    /// raised an inline card is a QUESTION, so it is classified separately and
    /// never counted here — pending or answered.
    private var statuses: [ChatShellToolSummary.Status] {
        messages.map {
            ChatShellToolSummary.status(
                kind: $0.metadata?.kind,
                ok: $0.metadata?.ok,
                resultSummary: $0.metadata?.resultSummary,
                resultStatus: $0.metadata?.resultStatus,
                interactionState: $0.metadata?.interactionState
            )
        }
    }

    private var failedCount: Int { statuses.filter { $0 == .failed }.count }
    private var needsYouCount: Int { statuses.filter { $0 == .needsYou }.count }

    private var details: [String] {
        zip(messages, statuses).map { message, status in
            ChatShellToolSummary.detailLine(
                toolName: message.metadata?.toolName,
                inputJSON: message.metadata?.inputJSON,
                // 2026-09-06: the outcome used to be dropped here, so a
                // write_file that failed still read "Wrote a file".
                status: status
            )
        }
    }

    var body: some View {
        let all = details
        let shown = Array(zip(messages, all).prefix(ChatShellToolSummary.detailLimit))
        let headline = ChatShellToolSummary.headline(
            count: messages.count, failed: failedCount, needsYou: needsYouCount)
        ChatActivityRow(title: headline, isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown, id: \.0.id) { pair in
                    ToolPillView(message: pair.0, headline: pair.1)
                }
                if let overflow = ChatShellToolSummary.overflowLine(
                    total: all.count, shown: shown.count
                ) {
                    Text(overflow)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .padding(.vertical, NativeAgentSpacing.xs)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
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

/// One orange card in the room describing the unfinished turn: what it
/// provably did, and the one retry that fits. The failed bubble above keeps
/// the cause; the raw error stays under Details.
struct ShellTroubleCard: View {
    /// The failed assistant row at the tail.
    var message: ChatMessage
    var failure: ChatTurnFailure
    var showsStuckLink: Bool
    var onRetry: () -> Void
    var onContinue: () -> Void
    var onOpenSettings: () -> Void
    @State private var confirming: ChatTurnFailure?
    @State private var showsDetails = false

    private var meta: ChatMessageMetadata? { message.metadata }
    /// Nil where Retry cannot run: a rejected turn that may have run steps is
    /// refused by regenerate itself, so the card offers no button it can't keep.
    private var retryLabel: String? {
        if meta?.providerRefusalDraft == true { return "Retry draft" }
        if meta?.providerRefusal == true { return nil }
        return "Try again"
    }
    private var rawDetail: String? {
        guard let raw = meta?.error?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != message.content else { return nil }
        return raw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(NativeAgentShell.trouble)
                Text(failure.line(model: meta?.model ?? meta?.requestedModel))
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.shell.trouble-line")
            }
            HStack(spacing: 14) {
                if let retryLabel {
                    Button(failure.retryNeedsConfirmation ? retryLabel + "\u{2026}" : retryLabel) {
                        if failure.retryNeedsConfirmation { confirming = failure } else { onRetry() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("chat.shell.trouble-retry")
                }
                if rawDetail != nil {
                    Button(showsDetails ? "Hide details" : "Details") { showsDetails.toggle() }
                        .buttonStyle(.plain)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .accessibilityIdentifier("chat.shell.trouble-details")
                }
                if showsStuckLink {
                    Button(ChatShellCopy.errorStuckLink, action: onOpenSettings)
                        .buttonStyle(.plain)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .underline()
                        .accessibilityIdentifier("chat.shell.stuck-settings-link")
                }
            }
            .padding(.leading, 24)
            if showsDetails, let rawDetail {
                Text(rawDetail)
                    .font(ShellType.code)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
        }
        .modifier(FailedTurnRetryConfirmation(failure: $confirming, onRetry: onRetry, onContinue: onContinue))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        .houseSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.shell.trouble-card")
    }
}
