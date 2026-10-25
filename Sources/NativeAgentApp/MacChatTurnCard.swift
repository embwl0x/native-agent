import EngineRuntime
import ApprovalTransactions
import ChatTurnRuntime
import SwiftUI
import ApprovalInbox
import CoreGraphics
import NativeAgentCore
import NativeAgentShared

// Blueprint: | `MacChatTurnCard.swift` | `MacChatTurnCard`: one display over canonical lifecycle state, shared by main/detached windows without card-local clocks or state machines |

/// The one live-work card for an accepted Mac chat turn.
///
/// Truth lives in ``MacChatTurnLifecycleState`` (Desk 658.10). This file owns
/// only display: a pure projection from the lifecycle owner's state to a
/// value the view renders, plus the single view that renders it. There is no
/// card-local state machine, no card-local clock, and no second progress
/// surface — the main window and every detached session window compose the
/// same ``MacChatTurnCardHost``.

enum MacChatTurnCardMetrics {
    /// Vertical room the transcript reserves so the floating card never covers
    /// the last message line.
    ///
    /// The card is bounded at two single-line rows (title, then one truncated
    /// detail line) inside `GlassCard`'s 16pt vertical padding, plus the 6pt
    /// bottom inset at the overlay: 32 + ~14 + 3 + ~12 + 6 ≈ 67pt at default
    /// text size. The margin above that is deliberate headroom for larger
    /// accessibility text sizes and taller locale metrics — the previous 56pt
    /// value could not fit the card at all.
    static let floatingClearance: CGFloat = 80
}

/// The single card component. Rendered identically by the main chat window and
/// by every detached session window.
struct MacChatTurnCard: View {
    let model: MacChatTurnCardModel
    /// Existing Stop affordance. When a surface already offers Stop it keeps
    /// working exactly as before.
    var onStop: (() -> Void)?
    /// Dispatches a decision for the turn's pending approval to the canonical
    /// inbox. The card carries no authority: it hands "approved"/"denied" to
    /// the same resolve path every other approval surface uses.
    var onDecideApproval: ((String) -> Void)?
    /// 2026-09-06: a decision is already on its way to the inbox. Both buttons
    /// stay visible and go inert — leaving them live invited a second press
    /// whose opposite decision the resolver could only discard.
    var isResolvingApproval: Bool = false

    @State private var isShowingPreviewSheet = false

    /// "Thought for 8s" while her reply streams, in place of "is working…".
    private var thoughtTitle: String? {
        guard let thoughtFor = model.thoughtFor else { return nil }
        return "Thought for \(MacChatTurnCardFormat.duration(max(1, thoughtFor)))"
    }

    /// Thumbnail geometry. 16:10 — a window shape, not a square — and sized to
    /// the height the card ALREADY has: its two text rows (title, then the
    /// caption line) measure ~30pt at default text size. Agent's rule, 2026-09-13:
    /// the pane may not buy itself room. A taller thumbnail grew the card and
    /// ate the gap above the composer, so the thumbnail fits the card instead of
    /// the card growing for the thumbnail.
    /// Measured, not guessed: the card's two text rows are 29pt at default text
    /// size (rendered card 61pt tall, less GlassCard's 16pt top and bottom), so
    /// 28pt fits inside them with a point to spare and the card's height is
    /// byte-identical with the pane and without it.
    private static let thumbnailHeight: CGFloat = 28
    private static let thumbnailWidth: CGFloat = 44.8

    /// What the agent is looking at, while it is driving the Mac. `nil` for
    /// every turn that never touches the four verbs, and the card then renders
    /// exactly as it always has.
    var preview: MacChatScreenPreview? = nil
    /// The main window's Work pane shows the screen full width, so there the
    /// caption opens it and the thumbnail and its sheet step aside. Nil in a
    /// detached window, which has no pane and keeps both.
    var onOpenScreen: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch model.tone {
        // A running turn is not "waiting on you", so it never wears the
        // teal accent (2026-09-23): a neutral dot on house glass.
        case .working: return NativeAgentShell.secondary
        case .attention: return NativeAgentTheme.warn
        case .failed: return NativeAgentTheme.fail
        // Unresolved and canceled are deliberately chromatic-neutral: an
        // unconfirmed outcome must not read as success or as an error.
        case .unresolved, .canceled: return .secondary
        }
    }

    var body: some View {
        GlassCard(tint: model.tone == .working ? nil : tint) {
            HStack(alignment: .center, spacing: NativeAgentSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                    leading
                        .frame(width: 12, alignment: .center)
                        .allowsHitTesting(false)

                    Group {
                        if let since = model.thinkingSince {
                            MacChatTurnThinkingTitle(since: since)
                        } else {
                            Text(thoughtTitle ?? model.title)
                                .font(NativeAgentFont.label)
                                .foregroundStyle(model.isTerminal ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .layoutPriority(2)
                    // Text glyphs have their own hit regions; a drag that
                    // starts on the title must reach the transcript below.
                    .allowsHitTesting(false)

                    Spacer(minLength: NativeAgentSpacing.sm)

                    // The thinking line carries its own clock.
                    if model.thinkingSince == nil {
                        MacChatTurnCardMetaText(
                            clock: model.clock,
                            isTerminal: model.isTerminal,
                            fallback: meta,
                            fallbackSpoken: model.spokenMeta
                        )
                        .allowsHitTesting(false)
                    }

                    // Controls outrank ALL text at narrow widths: at the
                    // detached-window floor (380pt) with a long meta readout,
                    // the approval decision — the card's only real steering
                    // affordance — used to be the thing squeezed off the
                    // right edge (sweep 2026-08-21). Priority order is now
                    // controls (3) > title (2) > badge (1) > meta (0), and
                    // fixedSize keeps button labels from clipping mid-glyph.
                    if let approval = model.approval, approval.isActionable, let onDecideApproval {
                        Button("Approve") {
                            guard !isResolvingApproval else { return }
                            onDecideApproval("approved")
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundStyle(NativeAgentTheme.ok)
                            .disabled(isResolvingApproval)
                            .help(isResolvingApproval
                                  ? "A decision is already being sent"
                                  : "Approve \(approval.toolName)")
                            .accessibilityLabel("Approve \(approval.toolName)")
                            .accessibilityIdentifier("chat.turn.approve")
                            .accessibilityAction {
                                guard !isResolvingApproval else { return }
                                onDecideApproval("approved")
                            }
                            .fixedSize()
                            .layoutPriority(3)
                        Button("Deny") {
                            guard !isResolvingApproval else { return }
                            onDecideApproval("denied")
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundStyle(NativeAgentTheme.fail)
                            .disabled(isResolvingApproval)
                            .help(isResolvingApproval
                                  ? "A decision is already being sent"
                                  : "Deny \(approval.toolName)")
                            .accessibilityLabel("Deny \(approval.toolName)")
                            .accessibilityIdentifier("chat.turn.deny")
                            .accessibilityAction {
                                guard !isResolvingApproval else { return }
                                onDecideApproval("denied")
                            }
                            .fixedSize()
                            .layoutPriority(3)
                    } else if let approval = model.approval, !approval.isActionable {
                        // A settled approval never gets buttons; it says what
                        // it was, including when that is "we cannot tell".
                        Text(approval.badge)
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }

                    if !model.isTerminal, let onStop {
                        Button(action: onStop) {
                            Label("Stop", systemImage: "stop.fill")
                                .font(NativeAgentFont.tag)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(
                            model.cancellationPending
                                ? AnyShapeStyle(.tertiary)
                                : AnyShapeStyle(.secondary)
                        )
                        .disabled(model.cancellationPending)
                        .help(model.cancellationPending ? "Stop already requested" : "Stop this turn")
                        .accessibilityLabel("Stop this turn")
                        .accessibilityIdentifier("chat.turn.stop")
                        .fixedSize()
                        .layoutPriority(3)
                    }
                }

                if let detail = detailLine, !detail.isEmpty {
                    if showsPreviewPane, model.approval == nil, let onOpenScreen {
                        Button(action: onOpenScreen) {
                            Text(detail)
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .buttonStyle(.plain)
                        .help("See it in the Work pane")
                        .accessibilityLabel("What I am looking at: \(detail)")
                        .accessibilityHint("Opens the Work pane on Screen")
                        .accessibilityIdentifier("chat.turn.preview")
                        .padding(.leading, 12 + NativeAgentSpacing.sm)
                    } else {
                        Text(detail)
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(detail)
                            .padding(.leading, 12 + NativeAgentSpacing.sm)
                    }
                }

                // 2026-09-06: what the tool would run with. A decision asked
                // for over a tool name and "autonomy=<level>" is a decision
                // made blind.
                if let approval = model.approval, approval.isActionable,
                   let input = approval.inputSummary {
                    Text(input)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(input)
                        .accessibilityLabel("Input: \(input)")
                        .padding(.leading, 12 + NativeAgentSpacing.sm)
                }
            }

            if showsPreviewPane, onOpenScreen == nil, let preview, let image = preview.image {
                thumbnail(preview, image: image)
            }
            }
        }
        .sheet(isPresented: $isShowingPreviewSheet) { previewSheet }
        // The empty container path also excluded its borderless buttons from
        // mouse hit testing, even though accessibility could activate them.
        // Keep the inset card's bounds hittable; settled cards remain inert.
        .contentShape(Rectangle())
        .allowsHitTesting(model.hasControls || showsPreviewPane)
        // Children already read the title, detail, and elapsed/movement line;
        // a container label on top of them would announce everything twice.
        .accessibilityElement(children: .contain)
        // Identity is part of the view's identity: a new turn is a new card,
        // never an animated mutation of the previous turn's card.
        .id(model.identity.sessionId + "\u{1F}" + model.identity.turnId)
    }

    /// The line under the title. While the agent is driving the Mac the verb's
    /// own words win: "Looking at Safari" says more than "Using tool: screen",
    /// and it is the same line, not a third row.
    private var detailLine: String? {
        if showsPreviewPane, let caption = preview?.caption, model.approval == nil {
            return caption
        }
        return model.detail
    }

    /// Whether the live pane is on the glass at all. A settled turn shows no
    /// pane and claims no live words: the slot is cleared when the turn's
    /// intake closes, and this says so in the view too, so no ordering between
    /// the terminal reduce and that clear can leave a dead frame clickable over
    /// the transcript.
    private var showsPreviewPane: Bool {
        !model.isTerminal && preview?.isShowable == true
    }

    /// The live computer pane. A picture of the user's own screen, shown back to
    /// the user in the app that took it — it never leaves this process, and the
    /// capture side has already painted out every secure field.
    private func thumbnail(_ preview: MacChatScreenPreview, image: CGImage) -> some View {
        Button { isShowingPreviewSheet = true } label: {
            Image(decorative: image, scale: 2)
                .resizable()
                .aspectRatio(16.0 / 10.0, contentMode: .fill)
                .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous)
                        .strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        // Reachable without a mouse: Tab lands on it whatever the Full Keyboard
        // Access setting is, Space and Return open the sheet (the Button's own
        // activation), and the sheet's onExitCommand closes it on Escape.
        .focusable()
        .help("See a larger view of what the agent is looking at")
        .accessibilityLabel("What the agent is looking at: \(preview.caption)")
        .accessibilityIdentifier("chat.turn.preview")
        .accessibilityHint("Opens a larger view")
        .fixedSize()
        // Same rank as the card's other controls: at the detached window's
        // narrow floor the pane is the point, and must not be the thing
        // squeezed off the right edge.
        .layoutPriority(3)
    }

    @ViewBuilder
    private var previewSheet: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            if let preview, let image = preview.image {
                Text(preview.caption)
                    .font(NativeAgentFont.label)
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 880, maxHeight: 560)
                    .clipShape(RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous))
                Text("The live view while the agent works. Secure fields are painted out, and this picture is not saved.")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            } else {
                // The turn ended while this sheet was open. Say so rather than
                // leaving the last frame up as if work were still happening.
                Text("The agent has stopped looking at the screen.")
                    .font(NativeAgentFont.label)
            }
            HStack {
                Spacer()
                Button("Done") { isShowingPreviewSheet = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(NativeAgentSpacing.xl)
        .frame(minWidth: 480)
        // Escape closes it. Done carries Return.
        .onExitCommand { isShowingPreviewSheet = false }
    }

    @ViewBuilder
    private var leading: some View {
        if model.showsLiveIndicator {
            PulsingDot(color: tint, size: 7, animates: !reduceMotion)
        } else {
            Image(systemName: model.symbolName)
                .font(NativeAgentFont.tag)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        }
    }

    private var meta: String {
        MacChatTurnCardFormat.metaLine(
            elapsed: model.elapsed,
            secondsSinceMovement: model.secondsSinceMovement,
            isTerminal: model.isTerminal,
            separator: " \u{00B7} "
        )
    }
}

/// The trailing timing readout, and the ONLY part of the card on a one-second
/// schedule.
///
/// The 04:05 pin (2026-09-04) was a transcript layout cost, and this card is
/// one of the invalidations that never let it settle: the whole card — glass,
/// title, detail, buttons, pulsing dot — used to be rebuilt every second
/// because a string inside it counts seconds. Now the schedule sits on the
/// string. The card above it re-renders only when the turn's state actually
/// changes.
///
/// A terminal turn has nothing left to count, so it renders statically with no
/// schedule at all — as does a model built without a clock.
struct MacChatTurnCardMetaText: View {
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    let clock: MacChatTurnCardModel.Clock?
    let isTerminal: Bool
    /// What to show when there is no live clock: the string the model was
    /// projected with.
    let fallback: String
    let fallbackSpoken: String

    var body: some View {
        if let clock, !isTerminal, chatPageIsVisible {
            TimelineView(.periodic(from: clock.startedAt, by: 1)) { context in
                readout(at: context.date, clock: clock)
            }
        } else {
            label(visible: fallback, spoken: fallbackSpoken)
        }
    }

    @ViewBuilder
    private func readout(at instant: Date, clock: MacChatTurnCardModel.Clock) -> some View {
        let elapsed = clock.elapsed(at: instant)
        let movement = clock.secondsSinceMovement(at: instant)
        label(
            visible: MacChatTurnCardFormat.metaLine(
                elapsed: elapsed,
                secondsSinceMovement: movement,
                isTerminal: isTerminal,
                separator: " \u{00B7} "
            ),
            spoken: MacChatTurnCardFormat.metaLine(
                elapsed: elapsed,
                secondsSinceMovement: movement,
                isTerminal: isTerminal,
                separator: ", "
            )
        )
    }

    private func label(visible: String, spoken: String) -> some View {
        // The shell's secondary token, not the system's tertiary: the
        // readout must clear 4.5:1 on the card's glass.
        Text(visible)
            .font(NativeAgentFont.tag)
            .foregroundStyle(NativeAgentShell.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Fluid glass A1: "Thinking… 0:08", the card's title while she thinks before
/// saying or doing anything. A soft light crosses the word every 2s (none
/// under Reduce Motion); the clock is the system's timer text, so it advances
/// without re-rendering anything. When she starts, the card's title says
/// "Thought for 8s" while her reply streams.
struct MacChatTurnThinkingTitle: View {
    let since: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.xs) {
            Text("Thinking\u{2026}")
                .foregroundStyle(NativeAgentShell.secondary)
                .overlay {
                    if !reduceMotion {
                        GeometryReader { geometry in
                            let band = max(24, geometry.size.width * 0.6)
                            LinearGradient(
                                colors: [.clear, NativeAgentShell.text, .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: band)
                            .offset(x: sweep ? geometry.size.width : -band)
                        }
                        .mask { Text("Thinking\u{2026}") }
                    }
                }
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { sweep = true }
                }
            Text(timerInterval: since...Date.distantFuture, countsDown: false)
                .foregroundStyle(NativeAgentShell.secondary)
                .monospacedDigit()
        }
        .font(NativeAgentFont.label)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// Composes the card from the lifecycle owner for one exact session.
///
/// The clock: a live card advances on a single SwiftUI `TimelineView`
/// schedule tied to this view's lifetime, and only while the turn is live. A
/// settled turn renders on the static branch with no schedule at all, so
/// nothing free-runs per turn.
struct MacChatTurnCardHost: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    let sessionId: String
    var onStop: (() -> Void)?
    /// The main window passes its Work pane; detached windows pass nothing.
    var onOpenScreen: (() -> Void)? = nil

    /// Seconds between re-projections of the card. Only the derived `.stalled`
    /// phase depends on the clock here; the readout keeps its own second.
    static let phaseTick: TimeInterval = 5

    var body: some View {
        let state = appModel.engine.turns.lifecycle(for: sessionId)
        Group {
            if let state, !state.presentation.isTerminal, chatPageIsVisible {
                // The card itself is NOT on a one-second schedule any more —
                // its trailing readout is (MacChatTurnCardMetaText). The only
                // thing left here that the clock can change is the derived
                // `.stalled` phase, whose threshold is 90s
                // (TurnPresentationReducer.defaultStalledAfter), so a tick
                // five times coarser surfaces a stall within 5s of the same
                // instant while rebuilding the glass card a fifth as often.
                TimelineView(.periodic(from: state.presentation.startedAt, by: Self.phaseTick)) { context in
                    card(state: state, at: context.date)
                }
            } else {
                card(
                    state: state,
                    at: state?.presentation.endedAt
                        ?? state?.presentation.lastMovementAt
                        ?? .distantPast
                )
            }
        }
    }

    @ViewBuilder
    private func card(state: MacChatTurnLifecycleState?, at instant: Date) -> some View {
        // `appModel.engine.approvals.records` IS the canonical inbox as this process last read
        // it — the same rows Activity → Approvals renders, refreshed by the
        // existing approvals file watch. The card opens no reader of its own.
        if let model = MacChatTurnCardProjection.card(
            for: state,
            sessionId: sessionId,
            personaName: appModel.agentDisplayName,
            at: instant,
            approvals: appModel.engine.approvals.records,
            parseTimestamp: UserDisplayFormatters.parseFoundationISOTimestamp
        ) {
            MacChatTurnCard(
                model: model,
                onStop: onStop,
                onDecideApproval: model.approval?.isActionable == true
                    ? { decision in decideApproval(model, decision: decision) }
                    : nil,
                isResolvingApproval: model.approval.map {
                    appModel.isResolvingApproval(id: $0.approvalId)
                } ?? false,
                // Present only while this session's turn is actually driving the
                // Mac; the app clears the slot when the turn opens and when its
                // intake closes, so a settled card never carries a frame.
                preview: appModel.engine.turns.screenPreview(for: sessionId),
                onOpenScreen: onOpenScreen
            )
        }
    }

    /// Hands the decision to the canonical resolve path and refreshes the rows
    /// this card projects. No local "resolved" flag: the next projection reads
    /// the inbox's own answer, so a failed resolve leaves the card actionable
    /// instead of pretending the decision landed.
    private func decideApproval(_ model: MacChatTurnCardModel, decision: String) {
        guard let approvalId = model.approval?.approvalId, !approvalId.isEmpty else { return }
        Task { @MainActor in
            do {
                _ = try await appModel.resolveApproval(id: approvalId, decision: decision)
            } catch ApprovalInboxError.alreadyResolved {
                // Stale card: re-read the inbox so it settles to the real decision.
                await appModel.engine.approvals.refresh()
            } catch {
                appModel.systemToasts.push(
                    error: UserFacingError.message(error, action: "record that decision")
                )
            }
            await appModel.refreshSidebarActivityBadge()
        }
    }
}

extension MacChatTurnCardApproval {
    /// Short badge for a card whose title belongs to the turn.
    var badge: String {
        switch outcome {
        case .pending: return "Needs approval"
        case .approved: return "Approved"
        case .denied: return "Denied"
        case .expired: return "Approval expired"
        case .unresolved: return "Approval unresolved"
        }
    }
}
