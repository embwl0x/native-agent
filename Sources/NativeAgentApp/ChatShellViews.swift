import ChatTurnRuntime
import ChatSessionWork
import Transcripts
import EngineRuntime
import SwiftUI
import NativeAgentShared
import TrustCenter
// Blueprint: | `ChatShellViews.swift` | `ShellRoomHeader`, `ShellConversationRow`: Shared header and owner-read subtitles |

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
    var session: ChatSession
    var openingLines: ChatShellOpeningLine
    var selected: Bool
    var isPinned: Bool
    /// Show pin controls only while hovered or pinned to keep ordinary rows quiet.
    var onTogglePin: () -> Void = {}

    @State private var hovering = false
    @FocusState private var pinFocused: Bool

    var body: some View {
        // Native List owns selection; rows only display their content.
        let title = ChatShellConversationRow.title(for: session)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .truncationMode(.tail)
            // Use previews to distinguish conversations without rewriting their titles.
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
    var content: String
    @State private var expanded = false

    var body: some View {
        ChatActivityRow(title: ChatShellEnvelope.headline(content), isExpanded: $expanded) {
            Text(DelegatedReplyEnvelope(content).reply)
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

/// Report proven effects and a valid retry in the trouble card; retain the cause and raw error in the failed bubble.
struct ShellTroubleCard: View {
    var message: ChatMessage
    var failure: ChatTurnFailure
    var showsStuckLink: Bool
    var onRetry: () -> Void
    var onContinue: () -> Void
    var onOpenSettings: () -> Void
    @State private var confirming: ChatTurnFailure?
    @State private var showsDetails = false

    private var meta: ChatMessageMetadata? { message.metadata }
    /// Offer Retry only when regenerate can honor it; uncertain prior effects require the shared refusal or confirmation.
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
