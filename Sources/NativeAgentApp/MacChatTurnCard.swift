import SwiftUI
import NativeAgentCore
import NativeAgentShared

/// The one live-work card for an accepted Mac chat turn.
///
/// Truth lives in ``MacChatTurnLifecycleState`` (Desk 658.10). This file owns
/// only display: a pure projection from the lifecycle owner's state to a
/// value the view renders, plus the single view that renders it. There is no
/// card-local state machine, no card-local clock, and no second progress
/// surface — the main window and every detached session window compose the
/// same ``MacChatTurnCardHost``.

/// Display-only projection of one accepted turn. Every field is derived; none
/// is stored, mutated, or remembered by the view layer.
struct MacChatTurnCardModel: Sendable, Equatable {
    /// Visual register. Deliberately separate from phase so that
    /// outcome-unknown can never be rendered with the success or failure
    /// treatment even if a future phase is added to the working family.
    enum Tone: Sendable, Equatable {
        /// The turn is moving. Accent, live indicator.
        case working
        /// Observationally stuck or blocked. Warm, but not an error.
        case attention
        /// Terminal and honest about not knowing. Neither green nor red.
        case unresolved
        /// Terminal failure asserted by typed evidence.
        case failed
        /// Terminal stop acknowledged by typed evidence.
        case canceled
    }

    let identity: MacChatTurnIdentity
    /// The effective phase, including the derived observational `.stalled`.
    let phase: TurnPresentationPhase
    let title: String
    let detail: String?
    let delegateName: String?
    let tone: Tone
    let symbolName: String
    let isTerminal: Bool
    let showsLiveIndicator: Bool
    /// Wall time the turn has been open (live) or was open (terminal).
    let elapsed: TimeInterval
    /// Seconds since the last observed movement; `nil` once terminal, because
    /// a settled turn has nothing left to move.
    let secondsSinceMovement: TimeInterval?
    /// A stop was requested and no terminal evidence has arrived yet.
    /// Requesting a stop is not proof the turn stopped.
    let cancellationPending: Bool
    /// The canonical approval this turn asked for, if any. Projected from the
    /// ApprovalInbox rows the app already holds — the card stores no approval
    /// state of its own and decides nothing.
    let approval: MacChatTurnCardApproval?

    /// True only while the card still offers something to click. A settled
    /// card with no pending decision floats over the transcript and must be
    /// inert; one holding a live approval must not be.
    var hasControls: Bool {
        !isTerminal || approval?.isActionable == true
    }

    /// Spoken form of the trailing timing readout. The visual string joins its
    /// parts with a middle dot and uses monospaced digits; read verbatim by
    /// VoiceOver that becomes punctuation noise, so the same facts are spoken
    /// as a sentence instead.
    var spokenMeta: String {
        var parts = [MacChatTurnCardFormat.elapsedPhrase(elapsed, isTerminal: isTerminal)]
        if let movement = MacChatTurnCardFormat.movementPhrase(secondsSinceMovement) {
            parts.append(movement)
        }
        return parts.joined(separator: ", ")
    }
}

enum MacChatTurnCardProjection {
    /// Threshold at which "no movement" becomes worth saying out loud. Below
    /// the stall threshold this is informational only, not a verdict.
    static let movementNoticeAfter: TimeInterval = 20

    /// The single projection seam. Returns `nil` when there is nothing left to
    /// say — no turn, a turn belonging to another session, or a turn whose
    /// outcome the transcript already carries.
    ///
    /// A card has no dismiss affordance and nothing clears a settled turn
    /// except the next turn in that session, so anything left visible here is
    /// permanent chrome floating over the transcript until the user sends
    /// again. That is only worth paying for a state the transcript CANNOT
    /// express. It can express all three proven terminals: `.completed` is the
    /// answer itself, `.failed` always lands with its error bubble, and
    /// `.canceled` leaves the partial reply the user stopped. `.outcomeUnknown`
    /// is the one terminal with no transcript representation — the whole point
    /// of the evidence work is that "we do not know how this ended" gets said
    /// out loud — so it alone keeps its card.
    ///
    /// Time-invariant visibility. Whether a card exists at all depends only on
    /// identity and settled phase, never on the clock — so layout gating and
    /// the card itself can never disagree for a frame.
    static func isVisible(_ state: MacChatTurnLifecycleState?, sessionId: String) -> Bool {
        guard let state, !sessionId.isEmpty,
              state.identity.sessionId == sessionId else { return false }
        switch state.presentation.phase {
        case .completed, .failed, .canceled:
            return false
        case .acknowledged, .working, .tool, .delegation, .retrying,
             .waiting, .blocked, .stalled, .outcomeUnknown:
            return true
        }
    }

    /// Visibility including the turn's approval (Desk 658.12). A turn that
    /// finished cleanly still keeps its card while the approval it asked for is
    /// pending or ended unproven — those are precisely the states the
    /// transcript cannot express. A proven approve/deny adds no chrome.
    ///
    /// Still time-invariant: nothing here reads a clock.
    static func isVisible(
        _ state: MacChatTurnLifecycleState?,
        sessionId: String,
        approvals: [ApprovalRequest]
    ) -> Bool {
        if isVisible(state, sessionId: sessionId) { return true }
        guard let state, !sessionId.isEmpty,
              state.identity.sessionId == sessionId else { return false }
        return approval(for: state, approvals: approvals)?.keepsCardVisible == true
    }

    static func approval(
        for state: MacChatTurnLifecycleState,
        approvals: [ApprovalRequest]
    ) -> MacChatTurnCardApproval? {
        MacChatTurnApprovalProjection.approval(
            sessionId: state.identity.sessionId,
            turnStartedAt: state.presentation.startedAt,
            approvals: approvals
        )
    }

    static func card(
        for state: MacChatTurnLifecycleState?,
        sessionId: String,
        personaName: String,
        at instant: Date,
        approvals: [ApprovalRequest] = [],
        stalledAfter: TimeInterval = TurnPresentationReducer.defaultStalledAfter
    ) -> MacChatTurnCardModel? {
        // Identity fence. A card belongs to exactly one session and one turn;
        // a state routed to the wrong surface renders nothing rather than
        // cross-rendering another conversation's work.
        guard let state,
              isVisible(state, sessionId: sessionId, approvals: approvals) else { return nil }

        let approval = approval(for: state, approvals: approvals)
        let presentation = state.presentation
        let isTerminal = presentation.isTerminal
        let phase = isTerminal
            ? presentation.phase
            : state.effectivePhase(at: instant, stalledAfter: stalledAfter)
        // A completed turn keeps a card only for an approval whose outcome is
        // not proven; the approval then owns what the card says.
        let approvalOwnsCard = approval?.outcome == .pending
            || (phase == .completed && approval?.keepsCardVisible == true)
        guard phase != .completed || approvalOwnsCard else { return nil }

        // Quantized to whole seconds on purpose. `lastMovementAt` advances on
        // every streamed token; without this the projected model would differ
        // on every token and re-render the glass card at token rate instead of
        // at the one-second cadence the card actually displays.
        let sinceMovement = isTerminal
            ? nil
            : wholeSeconds(instant.timeIntervalSince(presentation.lastMovementAt))
        let elapsedEnd = presentation.endedAt ?? instant
        let elapsed = wholeSeconds(elapsedEnd.timeIntervalSince(presentation.startedAt))
        let cancellationPending = !isTerminal && state.cancellationRequestedAt != nil

        let ownedApproval = approvalOwnsCard ? approval : nil
        return MacChatTurnCardModel(
            identity: state.identity,
            phase: phase,
            title: ownedApproval.map(approvalTitle(for:)) ?? title(
                phase: phase,
                personaName: personaName,
                delegateName: presentation.delegateName,
                cancellationPending: cancellationPending
            ),
            detail: ownedApproval.map(approvalDetail(for:))
                ?? detail(phase: phase, currentAction: presentation.currentAction),
            delegateName: presentation.delegateName,
            tone: ownedApproval.map(tone(forApproval:)) ?? tone(for: phase),
            symbolName: ownedApproval.map(symbolName(forApproval:)) ?? symbolName(for: phase),
            isTerminal: isTerminal,
            // A turn waiting on a person is not moving, whatever its last
            // lifecycle event was.
            showsLiveIndicator: ownedApproval == nil && !isTerminal && isMoving(phase),
            elapsed: elapsed,
            secondsSinceMovement: sinceMovement,
            cancellationPending: cancellationPending,
            approval: approval
        )
    }

    /// The approval's own words, used when the approval owns the card.
    static func approvalTitle(for approval: MacChatTurnCardApproval) -> String {
        switch approval.outcome {
        case .pending: return "Approve \(approval.toolName)?"
        case .approved: return "Approved \(approval.toolName)"
        case .denied: return "Denied \(approval.toolName)"
        case .expired: return "Approval expired"
        case .unresolved: return "Approval outcome unknown"
        }
    }

    static func approvalDetail(for approval: MacChatTurnCardApproval) -> String {
        switch approval.outcome {
        case .pending:
            if let reason = approval.reason {
                return "\(reason) \u{2014} the tool has not run."
            }
            return "This tool has not run. It is waiting for your decision."
        case .approved:
            return "You approved this. It runs through the usual safety checks."
        case .denied:
            return "You denied this. The tool did not run."
        case .expired:
            return "This request ended before anyone decided. The tool did not run."
        case .unresolved:
            return "This request settled without a readable decision. Whether the tool ran cannot be proven from here."
        }
    }

    static func tone(forApproval approval: MacChatTurnCardApproval) -> MacChatTurnCardModel.Tone {
        switch approval.outcome {
        case .pending: return .attention
        case .approved: return .working
        case .denied: return .canceled
        // An unproven outcome is neither success nor error.
        case .expired, .unresolved: return .unresolved
        }
    }

    static func symbolName(forApproval approval: MacChatTurnCardApproval) -> String {
        switch approval.outcome {
        case .pending: return "lock.shield"
        case .approved: return "checkmark.shield"
        case .denied: return "xmark.shield"
        case .expired: return "clock.badge.xmark"
        case .unresolved: return "questionmark.circle"
        }
    }

    private static func wholeSeconds(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return 0 }
        return interval.rounded(.down)
    }

    /// Phases in which the turn is understood to be actively moving.
    private static func isMoving(_ phase: TurnPresentationPhase) -> Bool {
        switch phase {
        case .acknowledged, .working, .tool, .delegation, .retrying:
            return true
        // `.waiting` is deliberately NOT "moving": the shared kernel refuses to
        // let a waiting turn become stalled, so a live pulse here would animate
        // forever with no escape and claim motion that is not happening.
        case .waiting, .blocked, .stalled, .completed, .failed, .canceled, .outcomeUnknown:
            return false
        }
    }

    static func title(
        phase: TurnPresentationPhase,
        personaName: String,
        delegateName: String?,
        cancellationPending: Bool
    ) -> String {
        let persona = personaName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = persona.isEmpty ? "The agent" : persona
        if cancellationPending, !phase.isTerminal {
            return "Stopping \(who)\u{2026}"
        }
        switch phase {
        case .acknowledged:
            return "\(who) is starting\u{2026}"
        case .working:
            return "\(who) is working\u{2026}"
        case .tool:
            return "\(who) is using a tool"
        case .delegation:
            if let delegateName, !delegateName.isEmpty {
                return "\(who) is working with \(delegateName)"
            }
            return "\(who) is delegating"
        case .retrying:
            return "\(who) is retrying\u{2026}"
        case .waiting:
            return "\(who) is waiting\u{2026}"
        case .blocked:
            return "\(who) is blocked"
        case .stalled:
            return "No movement from \(who)"
        case .completed:
            // Never rendered: `card(for:)` returns nil for a completed turn.
            return "Done"
        case .failed:
            return "This turn failed"
        case .canceled:
            return "This turn was stopped"
        case .outcomeUnknown:
            return "Outcome unknown"
        }
    }

    static func detail(phase: TurnPresentationPhase, currentAction: String?) -> String? {
        let action = currentAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let action, !action.isEmpty { return action }
        switch phase {
        case .stalled:
            return "Nothing has moved for a while. This is an observation, not a verdict \u{2014} it clears on the next sign of work."
        case .outcomeUnknown:
            return "This turn ended without proof of how it finished. It may or may not have completed."
        default:
            return nil
        }
    }

    static func tone(for phase: TurnPresentationPhase) -> MacChatTurnCardModel.Tone {
        switch phase {
        case .acknowledged, .working, .tool, .delegation, .retrying, .waiting, .completed:
            return .working
        case .blocked, .stalled:
            return .attention
        case .failed:
            return .failed
        case .canceled:
            return .canceled
        case .outcomeUnknown:
            return .unresolved
        }
    }

    static func symbolName(for phase: TurnPresentationPhase) -> String {
        switch phase {
        case .acknowledged: return "sparkles"
        case .working: return "gearshape"
        case .tool: return "wrench.and.screwdriver"
        case .delegation: return "person.2"
        case .retrying: return "arrow.clockwise"
        case .waiting: return "hourglass"
        case .blocked: return "hand.raised"
        case .stalled: return "clock.badge.questionmark"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .canceled: return "stop.circle"
        case .outcomeUnknown: return "questionmark.circle"
        }
    }
}

enum MacChatTurnCardFormat {
    /// Compact, calm duration. Seconds under a minute, then m/s, then h/m.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 {
            let minutes = total / 60
            let rest = total % 60
            return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    static func elapsedPhrase(_ seconds: TimeInterval, isTerminal: Bool) -> String {
        isTerminal ? "Ran for \(duration(seconds))" : "\(duration(seconds)) elapsed"
    }

    /// Only worth saying once movement has actually gone quiet.
    static func movementPhrase(_ secondsSinceMovement: TimeInterval?) -> String? {
        guard let secondsSinceMovement,
              secondsSinceMovement >= MacChatTurnCardProjection.movementNoticeAfter else {
            return nil
        }
        return "no movement for \(duration(secondsSinceMovement))"
    }
}

// MARK: - View

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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch model.tone {
        case .working: return NativeAgentBrand.accent
        case .attention: return NativeAgentTheme.warn
        case .failed: return NativeAgentTheme.fail
        // Unresolved and canceled are deliberately chromatic-neutral: an
        // unconfirmed outcome must not read as success or as an error.
        case .unresolved, .canceled: return .secondary
        }
    }

    var body: some View {
        GlassCard(tint: tint) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                    leading
                        .frame(width: 12, alignment: .center)

                    Text(model.title)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(model.isTerminal ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(2)

                    Spacer(minLength: NativeAgentSpacing.sm)

                    Text(meta)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .accessibilityLabel(model.spokenMeta)
                        .accessibilityAddTraits(.updatesFrequently)

                    if let approval = model.approval, approval.isActionable, let onDecideApproval {
                        Button("Approve") { onDecideApproval("approved") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(NativeAgentTheme.ok)
                            .help("Approve \(approval.toolName)")
                            .accessibilityLabel("Approve \(approval.toolName)")
                        Button("Deny") { onDecideApproval("denied") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(NativeAgentTheme.fail)
                            .help("Deny \(approval.toolName)")
                            .accessibilityLabel("Deny \(approval.toolName)")
                    } else if let approval = model.approval, !approval.isActionable {
                        // A settled approval never gets buttons; it says what
                        // it was, including when that is "we cannot tell".
                        Text(approval.badge)
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
                        .layoutPriority(1)
                    }
                }

                if let detail = model.detail, !detail.isEmpty {
                    Text(detail)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(detail)
                        .padding(.leading, 12 + NativeAgentSpacing.sm)
                }
            }
        }
        // A card with nothing to click floats over the transcript, so it must
        // not swallow clicks or text selection in the strip it covers. A
        // settled turn still holding a pending approval DOES have controls.
        .allowsHitTesting(model.hasControls)
        // Children already read the title, detail, and elapsed/movement line;
        // a container label on top of them would announce everything twice.
        .accessibilityElement(children: .contain)
        // Identity is part of the view's identity: a new turn is a new card,
        // never an animated mutation of the previous turn's card.
        .id(model.identity.sessionId + "\u{1F}" + model.identity.turnId)
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
        var parts = [MacChatTurnCardFormat.elapsedPhrase(model.elapsed, isTerminal: model.isTerminal)]
        if let movement = MacChatTurnCardFormat.movementPhrase(model.secondsSinceMovement) {
            parts.append(movement)
        }
        return parts.joined(separator: " \u{00B7} ")
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
    let sessionId: String
    var onStop: (() -> Void)?

    var body: some View {
        let state = appModel.chatTurnLifecycle(for: sessionId)
        Group {
            if let state, !state.presentation.isTerminal {
                TimelineView(.periodic(from: state.presentation.startedAt, by: 1)) { context in
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
        // `appModel.approvals` IS the canonical inbox as this process last read
        // it — the same rows Activity → Approvals renders, refreshed by the
        // existing approvals file watch. The card opens no reader of its own.
        if let model = MacChatTurnCardProjection.card(
            for: state,
            sessionId: sessionId,
            personaName: appModel.agentDisplayName,
            at: instant,
            approvals: appModel.approvals
        ) {
            MacChatTurnCard(
                model: model,
                onStop: onStop,
                onDecideApproval: model.approval?.isActionable == true
                    ? { decision in decideApproval(model, decision: decision) }
                    : nil
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
            } catch {
                appModel.systemToasts.push(
                    error: "Approval failed: \(error.localizedDescription)"
                )
            }
            await appModel.refreshSidebarActivityBadge()
        }
    }
}
