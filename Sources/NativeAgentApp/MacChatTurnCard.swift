import EngineRuntime
import ApprovalTransactions
import ChatTurnRuntime
import SwiftUI
import ApprovalInbox
import CoreGraphics
import NativeAgentCore
import NativeAgentShared

// Blueprint: | `MacChatTurnCard.swift` | `MacChatTurnCard`: main/detached display over canonical turn lifecycle |

/// Project MacChatTurnLifecycleState without local clocks or state machines so main and detached windows share one turn truth.

enum MacChatTurnCardMetrics {
    /// Reserve room for two rows, 16pt vertical padding and a 6pt overlay inset (~67pt), plus headroom for accessible text and locale metrics.
    static let floatingClearance: CGFloat = 80
}

struct MacChatTurnCard: View {
    let model: MacChatTurnCardModel
    var onStop: (() -> Void)?
    /// The card has no approval authority; send decisions to the canonical resolver.
    var onDecideApproval: ((String) -> Void)?
    var isResolvingApproval: Bool = false

    @State private var isShowingPreviewSheet = false

    private var thoughtTitle: String? {
        guard let thoughtFor = model.thoughtFor else { return nil }
        return "Thought for \(MacChatTurnCardFormat.duration(max(1, thoughtFor)))"
    }

    private static let thumbnailHeight: CGFloat = 28
    private static let thumbnailWidth: CGFloat = 44.8

    var preview: MacChatScreenPreview? = nil
    var onOpenScreen: (() -> Void)? = nil

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
                    // Let title drags reach the transcript; text glyphs keep their own hit regions.
                    .allowsHitTesting(false)

                    Spacer(minLength: NativeAgentSpacing.sm)

                    if model.thinkingSince == nil {
                        MacChatTurnCardMetaText(
                            clock: model.clock,
                            isTerminal: model.isTerminal,
                            fallback: meta,
                            fallbackSpoken: model.spokenMeta
                        )
                        .allowsHitTesting(false)
                    }

                    // Prioritize controls over title, badge and metadata so button labels survive narrow widths.
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
        // Keep the inset bounds hittable for borderless buttons; settled cards remain inert.
        .contentShape(Rectangle())
        .allowsHitTesting(model.hasControls || showsPreviewPane)
        // Avoid a container label because children already announce the same content.
        .accessibilityElement(children: .contain)
        // Give each turn a new view identity so it cannot animate from the preceding turn's card.
        .id(model.identity.sessionId + "\u{1F}" + model.identity.turnId)
    }

    private var detailLine: String? {
        if showsPreviewPane, let caption = preview?.caption, model.approval == nil {
            return caption
        }
        return model.detail
    }

    /// Gate live panes on terminal state as well as intake cleanup so ordering cannot leave a dead frame clickable.
    private var showsPreviewPane: Bool {
        !model.isTerminal && preview?.isShowable == true
    }

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

    private var meta: String {
        MacChatTurnCardFormat.metaLine(
            elapsed: model.elapsed,
            secondsSinceMovement: model.secondsSinceMovement,
            isTerminal: model.isTerminal,
            separator: " \u{00B7} "
        )
    }
}

/// Tick only timing text; terminal turns and models without clocks stay static.
struct MacChatTurnCardMetaText: View {
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    let clock: MacChatTurnCardModel.Clock?
    let isTerminal: Bool
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

/// Schedule live cards only while mounted and active so settled turns cannot keep a timer running.
struct MacChatTurnCardHost: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    let sessionId: String
    var onStop: (() -> Void)?
    var onOpenScreen: (() -> Void)? = nil

    /// Only derived stalled state depends on this clock; elapsed text owns its separate cadence.
    static let phaseTick: TimeInterval = 5

    var body: some View {
        let state = appModel.engine.turns.lifecycle(for: sessionId)
        Group {
            if let state, !state.presentation.isTerminal, chatPageIsVisible {
                // A five-second cadence detects the 90-second stall threshold within five seconds while avoiding per-second glass-card rebuilds.
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
        // Read AppModel's watched canonical approval records so the card cannot drift in a second inbox reader.
        if let model = TurnCardReadout.card(
            for: state,
            sessionId: sessionId,
            personaName: appModel.agentDisplayName,
            at: instant,
            approvals: appModel.engine.approvals.records,
            parseTimestamp: NativeTimestampFormat.parseISO8601FractionalFirst
        ) {
            MacChatTurnCard(
                model: model,
                onStop: onStop,
                onDecideApproval: model.approval?.isActionable == true
                    ? { decision in decideApproval(model, decision: decision) }
                    : nil,
                isResolvingApproval: model.approval.map {
                    appModel.engine.approvals.isResolving(id: $0.approvalId)
                } ?? false,
                preview: appModel.engine.turns.screenPreview(for: sessionId),
                onOpenScreen: onOpenScreen
            )
        }
    }

    /// Resolve and refresh through the canonical inbox; a failed write must leave the card actionable.
    private func decideApproval(_ model: MacChatTurnCardModel, decision: String) {
        guard let approvalId = model.approval?.approvalId, !approvalId.isEmpty else { return }
        Task { @MainActor in
            do {
                _ = try await appModel.resolveApproval(id: approvalId, decision: decision)
            } catch ApprovalInboxError.alreadyResolved {
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
