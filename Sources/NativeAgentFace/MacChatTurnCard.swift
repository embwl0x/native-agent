import SwiftUI
import NativeAgentShared

// Blueprint: | `MacChatTurnCard.swift` | `MacChatTurnCard`: main/detached display of the shared turn face |

/// Main and detached windows draw the same finished turn face.

enum MacChatTurnCardMetrics {
    /// Reserve room for two rows, 16pt vertical padding and a 6pt overlay inset (~67pt), plus headroom for accessible text and locale metrics.
    static let floatingClearance: CGFloat = 80
}

struct MacChatTurnCard: View {
    let model: MacChatTurnCardModel
    var onStop: (() -> Void)?

    @State private var isShowingPreviewSheet = false

    private var thoughtTitle: String? {
        guard let thoughtFor = model.thoughtFor else { return nil }
        return "Thought for \(MacChatTurnCardFormat.duration(max(1, thoughtFor)))"
    }

    private static let thumbnailHeight: CGFloat = 28
    private static let thumbnailWidth: CGFloat = 44.8

    var preview: TurnFace.Preview? = nil
    var onOpenScreen: (() -> Void)? = nil
    /// This turn's last finished steps, oldest first, at most three.
    var done: [TurnFace.Step] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch model.tone {
        case .working: return NativeAgentShell.secondary
        case .attention: return NativeAgentTheme.warn
        case .failed: return NativeAgentTheme.fail
        // Unconfirmed and cancelled outcomes must not read as success or failure.
        case .unresolved, .canceled: return .secondary
        }
    }

    var body: some View {
        GlassCard(tint: model.tone == .working ? nil : tint) {
            HStack(alignment: .center, spacing: NativeAgentSpacing.md) {
            MacChatTurnStepAge(since: model.clock.stepStartedAt) { long in
            VStack(alignment: .leading, spacing: 3) {
                // Her last finished steps sit above the one she is on, newest at the bottom; older ones are not shown.
                if !done.isEmpty, !model.isTerminal, !model.cancellationPending, model.approval?.isActionable != true {
                    ForEach(done) { step in
                        HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                            Image(systemName: step.outcome == .ok ? "checkmark" : step.outcome == nil ? "minus" : "xmark")
                                .frame(width: 12, alignment: .center)
                                .accessibilityHidden(true)
                            Text(step.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(NativeAgentShell.secondary)
                    }
                    .allowsHitTesting(false)
                    Rectangle()
                        .fill(NativeAgentShell.hairline)
                        .frame(height: 0.5)
                        .padding(.vertical, 2)
                        .accessibilityHidden(true)
                }

                HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                    leading
                        .frame(width: 12, alignment: .center)
                        .allowsHitTesting(false)

                    Group {
                        if let since = model.thinkingSince {
                            MacChatTurnThinkingTitle(since: since)
                        } else {
                            Text(long ? model.longStepTitle ?? model.title : thoughtTitle ?? model.title)
                                .font(NativeAgentFont.label)
                                .foregroundStyle(model.isTerminal ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .layoutPriority(2)
                    // Let title drags reach the transcript; text glyphs keep their own hit regions.
                    .allowsHitTesting(false)

                    Spacer(minLength: NativeAgentSpacing.sm)

                    if model.thinkingSince == nil {
                        MacChatTurnCardMetaText(clock: model.clock)
                        .allowsHitTesting(false)
                    }

                    // The turn names where its approval stands; the approval's one card (its Inbox row in the conversation) decides it.
                    if let approval = model.approval {
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

                if long {
                    MacChatTurnLongStepLine()
                        .padding(.leading, 12 + NativeAgentSpacing.sm)
                        .padding(.vertical, 2)
                    Text("This step takes a while. Nothing is stuck.")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .padding(.leading, 12 + NativeAgentSpacing.sm)
                        .allowsHitTesting(false)
                }

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
            }

            if showsPreviewPane, onOpenScreen == nil, let preview, let image = preview.imageData {
                thumbnail(preview, image: image)
            }
            }
        }
        .sheet(isPresented: $isShowingPreviewSheet) { previewSheet }
        // Keep the inset bounds hittable for borderless buttons; settled cards remain inert.
        .contentShape(Rectangle())
        .allowsHitTesting(model.hasControls || showsPreviewPane)
        // Avoid a container label because children already announce the same content.
        .accessibilityElement(children: .contain)
        // Give each turn a new view identity so it cannot animate from the preceding turn's card.
        .id(model.identity.sessionId + "\u{1F}" + model.identity.turnId)
    }

    private var detailLine: String? {
        // A provider wait or reconnect is why nothing moves; it outranks the screen preview's caption.
        if [.waiting, .retrying].contains(model.phase) { return model.detail }
        if let failure = preview?.imageError, model.approval == nil { return failure }
        if showsPreviewPane, let caption = preview?.caption, model.approval == nil {
            return caption
        }
        return model.detail
    }

    /// Gate live panes on terminal state as well as intake cleanup so ordering cannot leave a dead frame clickable.
    private var showsPreviewPane: Bool {
        !model.isTerminal && preview?.isShowable == true
    }

    private func thumbnail(_ preview: TurnFace.Preview, image: Data) -> some View {
        Button { isShowingPreviewSheet = true } label: {
            TurnPreviewImage(data: image, caption: preview.caption)
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
        .focusable()
        .help("See a larger view of what the agent is looking at")
        .accessibilityLabel("What the agent is looking at: \(preview.caption)")
        .accessibilityIdentifier("chat.turn.preview")
        .accessibilityHint("Opens a larger view")
        .fixedSize()
        // Give the pane control equal priority so detached windows cannot squeeze it away.
        .layoutPriority(3)
    }

    @ViewBuilder
    private var previewSheet: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            if let preview, let image = preview.imageData {
                Text(preview.caption)
                    .font(NativeAgentFont.label)
                TurnPreviewImage(data: image, caption: preview.caption)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 880, maxHeight: 560)
                    .clipShape(RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous))
                Text("The live view while the agent works. Secure fields are painted out, and this picture is not saved.")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            } else {
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
}

/// Tick only timing text; terminal turns stay static.
struct MacChatTurnCardMetaText: View {
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    let clock: MacChatTurnCardModel.Clock

    var body: some View {
        if !clock.isTerminal, chatPageIsVisible {
            TimelineView(.periodic(from: clock.stepStartedAt ?? clock.startedAt, by: 1)) { context in
                readout(at: context.date, clock: clock)
            }
        } else {
            readout(at: clock.endedAt ?? clock.lastMovementAt, clock: clock)
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
                isTerminal: clock.isTerminal,
                separator: " \u{00B7} "
            ),
            spoken: MacChatTurnCardFormat.metaLine(
                elapsed: elapsed,
                secondsSinceMovement: movement,
                isTerminal: clock.isTerminal,
                separator: ", "
            )
        )
    }

    private func label(visible: String, spoken: String) -> some View {
        // Use shell secondary ink to clear 4.5:1 on the card's glass.
        Text(visible)
            .font(NativeAgentFont.tag)
            .foregroundStyle(NativeAgentShell.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Hands its content whether the running step has turned long, redrawing at that moment and not on a per-second tick.
struct MacChatTurnStepAge<Content: View>: View {
    let since: Date?
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        // One branch whether or not a step runs, so the box keeps its identity (its Stop button, its dot) across every step's start and end.
        let long = since?.addingTimeInterval(TurnFace.longStepAfter)
        // A periodic schedule from the step's start lands exactly on the long mark; the clock is also read at draw, so any redraw past the mark shows it.
        // With no step running there is nothing to mark, so the schedule is a year apart and the card is not redrawn.
        TimelineView(.periodic(from: since ?? .distantPast, by: since == nil ? 31_536_000 : TurnFace.longStepAfter)) { context in
            content(long.map { max(context.date, Date()) >= $0 } ?? false)
        }
    }
}

/// A thin accent line that keeps moving through a long step; under Reduce Motion it holds still.
struct MacChatTurnLongStepLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible

    var body: some View {
        Capsule()
            .fill(Color.accentColor.opacity(reduceMotion ? 0.6 : 0.2))
            .frame(height: 2)
            .overlay(alignment: .leading) {
                if !reduceMotion, chatPageIsVisible {
                    // Draw from the clock to avoid repeatForever layout recursion.
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        GeometryReader { geometry in
                            let band = max(24, geometry.size.width * 0.3)
                            let phase = NativeAgentMotion.loopPhase(at: context.date, period: 1.6)
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: band)
                                .offset(x: -band + phase * (geometry.size.width + band))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Use the system timer to advance thinking text without rebuilding the view; respect Reduce Motion.
struct MacChatTurnThinkingTitle: View {
    let since: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.xs) {
            Text("Thinking\u{2026}")
                .foregroundStyle(NativeAgentShell.secondary)
                .overlay {
                    if !reduceMotion {
                        // Draw from the clock to avoid repeatForever layout recursion.
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                            GeometryReader { geometry in
                                let band = max(24, geometry.size.width * 0.6)
                                let phase = NativeAgentMotion.loopPhase(at: context.date, period: 2)
                                LinearGradient(
                                    colors: [.clear, NativeAgentShell.text, .clear],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .frame(width: band)
                                .offset(x: -band + phase * (geometry.size.width + band))
                            }
                        }
                        .mask { Text("Thinking\u{2026}") }
                    }
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

/// Observe only this conversation's finished card and preview.
struct MacChatTurnCardHost: View {
    @Environment(AppModel.self) private var appModel
    let sessionId: String
    var onStop: (() -> Void)?
    var onOpenScreen: (() -> Void)? = nil

    var body: some View {
        let face = appModel.turnFace(for: sessionId)
        if let model = face?.card {
            VStack(alignment: .leading, spacing: 3) {
                MacChatTurnCard(model: model, onStop: onStop, preview: face?.preview, onOpenScreen: onOpenScreen,
                                // A step whose words the box is already showing as its current line is not listed again above it.
                                done: Array((face?.steps ?? []).filter { !$0.isRunning && $0.text != model.detail }.prefix(3).reversed()))
                if let status = face?.approvalStatus {
                    Text(status).font(NativeAgentFont.tag).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension MacChatTurnCardApproval {
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
