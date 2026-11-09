import ApprovalInbox
import ApprovalTransactions
import ChatTurnRuntime
import Foundation
@_exported import NativeAgentShared
// Blueprint: | `TurnCardReadout.swift` | `TurnCardReadout`; Off-main lifecycle and canonical approval projection |

public enum TurnCardReadout {
    /// Cross-room movement uses call names, never arguments, notices, approvals or conversation words.
    public static func movement(for state: MacChatTurnLifecycleState, runID: String?) -> TurnSessionsFace.Movement? {
        let turn = state.presentation
        guard !turn.isTerminal, let call = turn.lastCallName else { return nil }
        let line: String
        let moving: Bool
        if state.cancellationRequestedAt != nil {
            line = "Stopping…"
            moving = false
        } else if let writing = turn.writing {
            line = writing.line
            moving = true
        } else {
            switch turn.phase {
            case .tool, .delegation:
                line = ToolActivityPresentation.progress(call)
                moving = true
            case .acknowledged, .working:
                line = turn.streamedTextLength > 0 ? "Writing the reply" : "Thinking"
                moving = true
            case .waiting: line = "Waiting"; moving = false
            case .retrying: line = "Retrying"; moving = true
            case .blocked: line = "Blocked"; moving = false
            case .stalled: line = "No movement"; moving = false
            case .completed, .failed, .canceled, .outcomeUnknown: return nil
            }
        }
        return .init(identity: state.identity, runID: runID, line: line, isMoving: moving)
    }

    /// Identity and settled phase decide visibility, never clock age; unknown terminal outcomes remain visible.
    public static func isVisible(_ state: MacChatTurnLifecycleState?, sessionId: String) -> Bool {
        guard let state, !sessionId.isEmpty,
              state.identity.sessionId == sessionId else { return false }
        if state.replyTextSettled { return false }
        switch state.presentation.phase {
        case .completed, .failed, .canceled:
            return false
        case .acknowledged, .working, .tool, .delegation, .retrying,
             .waiting, .blocked, .stalled, .outcomeUnknown:
            return true
        }
    }

    /// Keep pending or unproven approval decisions reachable independently of clock age.
    public static func isVisible(
        _ state: MacChatTurnLifecycleState?,
        sessionId: String,
        approvals: [ApprovalRecord],
        parseTimestamp: (String) -> Date?
    ) -> Bool {
        if isVisible(state, sessionId: sessionId) { return true }
        guard let state, !sessionId.isEmpty,
              state.identity.sessionId == sessionId else { return false }
        return approval(for: state, approvals: approvals, parseTimestamp: parseTimestamp)?.keepsCardVisible == true
    }

    public static func approval(
        for state: MacChatTurnLifecycleState,
        approvals: [ApprovalRecord],
        parseTimestamp: (String) -> Date?
    ) -> MacChatTurnCardApproval? {
        TurnApprovalRead.approval(
            sessionId: state.identity.sessionId,
            turnStartedAt: state.presentation.startedAt,
            approvals: approvals,
            requester: NativeAgentChatApprovalFiler.requester(inTitle:),
            parseTimestamp: parseTimestamp
        )
    }

    public static func card(
        for state: MacChatTurnLifecycleState?,
        sessionId: String,
        personaName: String,
        approvals: [ApprovalRecord] = [],
        parseTimestamp: (String) -> Date?
    ) -> MacChatTurnCardModel? {
        // Require exact session and turn identity so a routed state cannot expose another conversation’s card.
        guard let state,
              isVisible(state, sessionId: sessionId, approvals: approvals, parseTimestamp: parseTimestamp) else { return nil }

        let approval = approval(for: state, approvals: approvals, parseTimestamp: parseTimestamp)
        let presentation = state.presentation
        let isTerminal = presentation.isTerminal
        let phase = presentation.phase
        // After completion, only unproven approval outcomes retain the card, and the approval owns its words.
        let approvalOwnsCard = approval?.outcome == .pending
            || (phase == .completed && approval?.keepsCardVisible == true)
        guard phase != .completed || approvalOwnsCard else { return nil }

        let cancellationPending = !isTerminal && state.cancellationRequestedAt != nil

        // Keep approval reachable while acknowledging Stop until actual settlement.
        let ownedApproval = approvalOwnsCard && !cancellationPending ? approval : nil
        // A call being written is work with a name, not thinking.
        let writing = phase == .stalled ? nil : presentation.writing
        let plain = !isTerminal && ownedApproval == nil && !cancellationPending
            && presentation.currentAction == nil && writing == nil
            && (phase == .acknowledged || phase == .working)
        return MacChatTurnCardModel(
            identity: state.identity,
            phase: phase,
            title: ownedApproval.map(approvalTitle(for:)) ?? title(
                phase: phase,
                personaName: personaName,
                delegateName: presentation.delegateName,
                cancellationPending: cancellationPending
            ),
            detail: cancellationPending ? "Waiting for this response to stop."
                : ownedApproval.map(approvalDetail(for:))
                    ?? writing?.line ?? detail(phase: phase, currentAction: presentation.currentAction),
            delegateName: presentation.delegateName,
            tone: ownedApproval.map(tone(forApproval:)) ?? tone(for: phase),
            symbolName: ownedApproval.map(symbolName(forApproval:)) ?? symbolName(for: phase),
            isTerminal: isTerminal,
            // Waiting on the person is not movement regardless of the last lifecycle event.
            showsLiveIndicator: ownedApproval == nil && !isTerminal && !cancellationPending && isMoving(phase),
            cancellationPending: cancellationPending,
            approval: approval,
            clock: MacChatTurnCardModel.Clock(
                startedAt: presentation.startedAt,
                endedAt: presentation.endedAt,
                lastMovementAt: presentation.lastMovementAt,
                isTerminal: isTerminal
            ),
            thinkingSince: plain && presentation.streamedTextLength == 0 ? presentation.startedAt : nil,
            thoughtFor: plain && presentation.streamedTextLength > 0
                ? presentation.firstReplyAt.map { $0.timeIntervalSince(presentation.startedAt) } : nil
        )
    }

    /// Use the approval’s own words when it owns the card.
    public static func approvalTitle(for approval: MacChatTurnCardApproval) -> String {
        switch approval.outcome {
        case .pending:
            // Name third-party askers first so requests cannot appear to be the agent’s own.
            if let requester = approval.requester {
                return "\(requester) asked: \(approval.act)?"
            }
            return "\(approval.act)?"
        case .approved: return "Approved: \(approval.act)"
        case .denied: return "Denied: \(approval.act)"
        case .expired: return "Approval expired"
        case .unresolved: return "Approval outcome unknown"
        }
    }

    public static func approvalDetail(for approval: MacChatTurnCardApproval) -> String {
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

    public static func tone(forApproval approval: MacChatTurnCardApproval) -> MacChatTurnCardModel.Tone {
        switch approval.outcome {
        case .pending: return .attention
        case .approved: return .working
        case .denied: return .canceled
        // An unproven outcome is neither success nor error.
        case .expired, .unresolved: return .unresolved
        }
    }

    public static func symbolName(forApproval approval: MacChatTurnCardApproval) -> String {
        switch approval.outcome {
        case .pending: return "lock.shield"
        case .approved: return "checkmark.shield"
        case .denied: return "xmark.shield"
        case .expired: return "clock.badge.xmark"
        case .unresolved: return "questionmark.circle"
        }
    }

    private static func isMoving(_ phase: TurnPresentationPhase) -> Bool {
        switch phase {
        case .acknowledged, .working, .tool, .delegation, .retrying:
            return true
        // Waiting is not movement; a live pulse would claim motion forever because the kernel does not stall waiting turns.
        case .waiting, .blocked, .stalled, .completed, .failed, .canceled, .outcomeUnknown:
            return false
        }
    }

    public static func title(
        phase: TurnPresentationPhase,
        personaName: String,
        delegateName: String?,
        cancellationPending: Bool
    ) -> String {
        let persona = personaName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = persona.isEmpty ? "The agent" : persona
        if cancellationPending, !phase.isTerminal {
            return "Stopping\u{2026}"
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
            // Completed turns render no card.
            return "Done"
        case .failed:
            return "This turn failed"
        case .canceled:
            return "This turn was stopped"
        case .outcomeUnknown:
            return "Not sure that finished."
        }
    }

    public static func detail(phase: TurnPresentationPhase, currentAction: String?) -> String? {
        let action = currentAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let action, !action.isEmpty { return action }
        switch phase {
        case .stalled:
            return "Nothing has moved for a while. This is an observation, not a verdict \u{2014} it clears on the next sign of work."
        case .outcomeUnknown:
            return "This reply did not finish before the app restarted."
        default:
            return nil
        }
    }

    public static func tone(for phase: TurnPresentationPhase) -> MacChatTurnCardModel.Tone {
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

    public static func symbolName(for phase: TurnPresentationPhase) -> String {
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
