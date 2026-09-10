import SwiftUI
import NativeAgentShared

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
    var status: ChatShellStatus
    var trustPolicy: TrustPolicy?

    // A single expiry boundary refreshes an idle header; policy changes come
    // from AppModel observation. No recurring permission poll.
    private var permissionRefreshDates: [Date] {
        let now = Date()
        if case .active(let expiry) = FullMacExpiry.state(trustPolicy, now: now) {
            return [now, expiry.addingTimeInterval(0.001)]
        }
        return [now]
    }
    /// The conversation's brain controls (model, thinking, capabilities). The
    /// NextGen phase pill, the token meter and the warnings pill left this bar;
    /// this toggle stays because it changes what she actually does, and losing
    /// it would be a removal, not a simplification.
    @Binding var showConversationControls: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(ShellType.title)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)

            // Agent, 2026-09-02, glyph diet: the magnifier that used to sit
            // here was the room's SECOND search box, next to the one over the
            // conversations list, and neither said which was which. The
            // transcript search kept its own way in — Chat ▸ Find in
            // Conversation… (⌘F) — so this one is simply gone.
            //
            // The remaining control carries its word instead of a slider
            // glyph a stranger has to click to identify.
            Button {
                withAnimation(NativeAgentMotion.respecting(
                    .easeOut(duration: 0.16), reduceMotion: reduceMotion
                )) {
                    showConversationControls.toggle()
                }
            } label: {
                Text("Conversation settings")
                    .font(ShellType.label)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(showConversationControls
                ? NativeAgentShell.text
                : NativeAgentShell.secondary)
            .help("Model, thinking and capabilities for this conversation")
            .accessibilityLabel("Conversation settings")
            .accessibilityValue(showConversationControls ? "Shown" : "Hidden")
            .accessibilityIdentifier("chat.header.conversation-settings-toggle")

            TimelineView(.explicit(permissionRefreshDates)) { context in
                let currentStatus: ChatShellStatus = if case .settled = status {
                    .settled(.make(policy: trustPolicy, now: context.date))
                } else {
                    status
                }
                Button {
                    NotificationCenter.default.post(name: .openCommandRouteRequest, object: "trust")
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(currentStatus.color)
                            .frame(width: 8, height: 8)
                        Text(currentStatus.text)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Review permissions in Trust")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(currentStatus.text). Open Trust")
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
        // The shell baseline: 20 semibold in a 24pt-tall row, 22 down from the
        // title strip, puts her name on window y 72 with "Chat" and
        // "Conversations".
        .padding(.top, 22)
        .padding(.bottom, 10)
    }
}

/// One vocabulary for every fold in the shell: rows arrive from the top edge
/// they were folded behind, and Reduce Motion drops the travel for a plain
/// fade. No stagger: Agent, 2026-09-03, read the burst — a 20ms row stagger
/// is under perception at the display's cadence, and raising it makes a fold
/// read as a list loading. A fold is one gesture: one fade, one height change.
enum ShellFoldMotion {
    static let open = Animation.smooth(duration: 0.3)

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .top))
    }

    static func rowAnimation(index: Int, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : open
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ChatShellConversationRow.title(for: session))
                        .font(ShellType.bodySemibold)
                        .foregroundStyle(NativeAgentShell.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(ChatShellConversationRow.subtitle(for: session))
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(ShellType.labelMedium)
                        .foregroundStyle(isPinned ? NativeAgentShell.text : NativeAgentShell.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isPinned || hovering ? 1 : 0)
                .help(isPinned ? "Unpin" : "Pin to the top")
                .accessibilityLabel(isPinned ? "Unpin conversation" : "Pin conversation to the top")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            // Fixed, never minimum: 46 plus the 2pt gap is a 48pt pitch, two
            // 24pt units, the same beat the rail runs. A minimum drifts.
            .frame(
                maxWidth: .infinity,
                minHeight: NativeAgentShellLayout.listRowHeight,
                maxHeight: NativeAgentShellLayout.listRowHeight,
                alignment: .leading
            )
            // Agent, 2026-09-02: "bar means here" in both columns. A flat wash
            // and the same 2pt bar the rail uses, 4pt in; no rounded tile, no
            // accent. Teal is the send button and needs-you, nothing else.
            // The column pads its content 12pt; the wash runs to the column's
            // edges and the bar sits 4pt in from the edge, same as the rail.
            .background {
                Rectangle()
                    .fill(selected
                        ? AnyShapeStyle(Color.primary.opacity(0.06))
                        : AnyShapeStyle(Color.primary.opacity(hovering ? 0.035 : 0)))
                    .padding(.horizontal, -12)
            }
            .overlay(alignment: .leading) {
                // Same bar, same rule as the rail: the selected row is the only
                // one that draws it, so it travels. Reduce Motion cross-fades.
                let bar = RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(NativeAgentShell.text)
                    .frame(width: 2, height: 20)
                    .padding(.leading, NativeAgentShellLayout.barInset - 12)
                if reduceMotion {
                    bar.opacity(selected ? 1 : 0)
                } else if selected {
                    bar.matchedGeometryEffect(
                        id: ShellConversationRow.selectionBarID,
                        in: barNamespace
                    )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .animation(
            NativeAgentMotion.respecting(.easeOut(duration: 0.15), reduceMotion: reduceMotion),
            value: hovering
        )
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.25),
            value: selected
        )
        .accessibilityLabel(ChatShellConversationRow.title(for: session))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Opens this conversation")
    }
}

/// The bridge and agent sessions, folded into one line with a chevron. They are
/// real conversations, so they expand in place rather than disappearing.
struct ShellWorkingGroupRow: View {
    var title: String = ChatShellCopy.workingRowTitle
    var count: Int
    var isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text(title)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("chat.shell.working-group")
    }
}

// MARK: - Tool traffic

/// A worker's reply, folded: the headline row opens onto the words, and the
/// routing slip it came wrapped in never renders here.
struct ShellEnvelopeRow: View {
    var content: String
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(NativeAgentMotion.respecting(
                    .smooth(duration: 0.3), reduceMotion: reduceMotion
                )) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(ShellType.labelSemibold)
                    Text(ChatShellEnvelope.headline(content))
                    Spacer(minLength: 8)
                    Text(expanded ? "Hide" : "Show")
                }
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(ChatShellEnvelope.reply(content))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 19)
                    .transition(ShellFoldMotion.transition(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        .background(
            NativeAgentShell.softFill,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

/// ONE quiet row per turn. Opening it says what she actually touched, in
/// sentences. Raw JSON never renders in the room — the Turn Inspector inside
/// Diagnostics is where a developer goes looking for it, and it is unchanged.
struct ShellToolRow: View {
    var messages: [ChatMessage]
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Only a recorded FALSE is a failure; most rows record no outcome at all
    /// (2026-09-06, same rule the detail lines use).
    private var failedCount: Int {
        messages.filter { $0.metadata?.ok == false }.count
    }

    private var details: [String] {
        messages.map {
            ChatShellToolSummary.detailLine(
                toolName: $0.metadata?.toolName,
                inputJSON: $0.metadata?.inputJSON,
                // 2026-09-06: the outcome used to be dropped here, so a
                // write_file that failed still read "Wrote a file".
                ok: $0.metadata?.ok
            )
        }
    }

    var body: some View {
        let all = details
        let shown = Array(all.prefix(ChatShellToolSummary.detailLimit))
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(NativeAgentMotion.respecting(
                    .smooth(duration: 0.3), reduceMotion: reduceMotion
                )) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(ShellType.labelSemibold)
                    Text(ChatShellToolSummary.headline(
                        count: messages.count, failed: failedCount))
                    Spacer(minLength: 8)
                    Text(expanded ? "Hide" : "Show")
                }
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shellKeyboardTarget(.receipt)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .textSelection(.enabled)
                    }
                    if let overflow = ChatShellToolSummary.overflowLine(
                        total: all.count, shown: shown.count
                    ) {
                        Text(overflow)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.tertiary)
                    }
                }
                .padding(.leading, 19)
                .transition(ShellFoldMotion.transition(reduceMotion: reduceMotion))
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        // Agent, 2026-09-03: the fold row is a hinge, not a card. No fill, no
        // border; chevron and words sit on the room like the rest of the turn.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChatShellToolSummary.headline(
            count: messages.count, failed: failedCount))
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
                            .background(
                                NativeAgentShell.quietFill,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
                            }
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

/// One orange card in the room. It says what happened and what did NOT happen,
/// because "your message is safe" is the sentence a person actually needs.
struct ShellTroubleCard: View {
    var showsStuckLink: Bool
    /// 2026-09-06: "Nothing was sent anywhere" is a claim about the turn, so
    /// it is shown only when the turn's tool receipts say it dispatched
    /// nothing. When tools did run the card carries the title alone.
    var showsNothingSentLine: Bool
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(NativeAgentShell.trouble)
                Text(ChatShellCopy.errorTitle)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
            }
            if showsNothingSentLine {
                Text(ChatShellCopy.errorDetail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            if showsStuckLink {
                Button(ChatShellCopy.errorStuckLink, action: onOpenSettings)
                    .buttonStyle(.plain)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .underline()
                    .padding(.top, 2)
                    .accessibilityIdentifier("chat.shell.stuck-settings-link")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        .background(
            NativeAgentShell.trouble.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(NativeAgentShell.trouble.opacity(0.30), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.shell.trouble-card")
    }
}
