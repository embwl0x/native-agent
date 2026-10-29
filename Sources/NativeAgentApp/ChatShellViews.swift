import ChatTurnRuntime
import ChatSessionWork
import Transcripts
import EngineRuntime
import SwiftUI
import NativeAgentShared
import TrustCenter
// Blueprint: | `ChatShellViews.swift` | `ShellRoomHeader`; `ShellConversationRow` reads subtitle timestamps from its injected transcript-root opening-line owner |

// MARK: - The header: her name and one dot

struct ShellRoomHeader: View {
    var name: String
    /// The dot shows waits and failures; the composer alone states settled trust.
    var status: ChatShellStatus
    /// Simple view starts a fresh thread here or through /new.
    var onNewChat: (() -> Void)? = nil
    /// Unread notes appear as one "N updates" capsule.
    var notes: InboxNotesCapsule? = nil
    /// The Work pane's button, main window only (WorkPane.swift).
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

            // Transcript search lives in Chat → Find in Conversation (⌘F).

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
        // The header shares the transcript and composer's column and inner gutter.
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

/// One row: a title a person recognises, and where and when it happened.
struct ShellConversationRow: View {
    var session: ChatSession
    var openingLines: ChatShellOpeningLine
    var selected: Bool
    var isPinned: Bool
    /// The row shows its pin control while hovered or pinned.
    var onTogglePin: () -> Void = {}

    @State private var hovering = false
    @FocusState private var pinFocused: Bool

    var body: some View {
        // Native List owns selection; the row displays its words and pin.
        let title = ChatShellConversationRow.title(for: session)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .truncationMode(.tail)
            // Last-line previews distinguish conversations without changing their titles.
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
                Text(ChatShellConversationRow.subtitle(for: session, openingLines: openingLines, relativeTimestamp: {
                    UserDisplayFormatters.relativeISOTimestamp($0, unitsStyle: .abbreviated, fallback: "")
                }))
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

/// Transcript activity shares one disclosure row with no fill or border.
struct ChatActivityRow<Leading: View, Detail: View>: View {
    let title: String
    var trailing: String = ""
    @Binding var isExpanded: Bool
    var accessibilityLabel: String? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var detail: () -> Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.readingPlace) private var readingPlace

    /// Where opened detail starts: past the chevron and its gap.
    static var indent: CGFloat { 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if !isExpanded { readingPlace?.opening() }
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
            Text(DelegatedReplyEnvelope(content).reply)
        }
    }
}

/// ONE quiet row per turn. Opening it says what she actually touched, in
/// sentences, and each sentence opens onto that call's result.
struct ShellToolRow: View {
    @Environment(AppModel.self) private var appModel
    var messages: [ChatMessage]
    @State private var expanded = false
    private struct Revision: Equatable, Sendable { let messages: [ChatMessage]; let expanded: Bool }
    @State private var preparedRevision: Revision?
    private var words: PresentationFaces { appModel.engine.transcripts.presentation }
    private var headlineKey: String { "headline:"+(messages.first?.id ?? "empty") }

    var body: some View {
        let shown=Array(messages.prefix(ChatShellToolSummary.detailLimit))
        let current=preparedRevision == Revision(messages:messages,expanded:expanded)
        let headline=current ? (words.words(headlineKey) ?? "Activity unavailable.") : "Reading activity…"
        ChatActivityRow(title:headline,isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:0) {
                ForEach(shown,id:\.id) { message in
                    ToolPillView(message:message,headline:current ? (words.words("detail:"+message.id) ?? "Readout unavailable.") : "Reading activity…")
                }
                if let overflow=ChatShellToolSummary.overflowLine(total:messages.count,shown:shown.count) {
                    Text(overflow).foregroundStyle(NativeAgentShell.tertiary).padding(.vertical,NativeAgentSpacing.xs)
                }
            }
        }
        .accessibilityElement(children:.contain)
        .accessibilityLabel(headline)
        .quietReadTask(id:Revision(messages:messages,expanded:expanded)) {
            let revision=Revision(messages:messages,expanded:expanded)
            await appModel.engine.transcripts.prepareToolFold(revision.messages, expanded: revision.expanded)
            if !Task.isCancelled { preparedRevision=revision }
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
