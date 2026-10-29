import ApprovalInbox
import ChatTurnRuntime
import ApprovalTransactions
import Foundation
import NativeAgentCore
@_exported import NativeAgentShared
import Connectors
import DeviceSync
import PersistenceCore
import ProviderRouting
import CloudKit
import DoctorChecks
import MemoryV2
import StandingBots
import Observation
import Cognition
import ChatToolRuntime
import ChatSessionWork
import ChatToolParsing
import SlackBot
import TelegramBot
import TriggerScheduler
import WorkshopExecution
import BackgroundLoops
import AppToolRuntime
import TrustCenter
import MacControl
import AttentionRouting
import Desk
import NotificationInbox
import ToolRegistry
import Transcripts
import ChatTurnContracts
import BackgroundWork
import DreamREMCycle
import AuthoredCapabilities
@preconcurrency import EventKit
import MacIntegration
import ToolExecution
import Senses
import Browser
import PersonaEngine
import AgentWorkspace
import Synchronization
import Studio
import Agents
import AgentConversations
import ChromeControl
import CognitiveSubstrate
import Context
import ContextFlow
import TurnTrace
import os
import TrustPersistence
import SwarmRuns
import Onboarding
import Privacy
import Experiences
import CryptoKit
import ActivityWatch
import OSLog
import Procedures
import SchedulerExecution
import Darwin
import Combine
import UserNotifications
import Research
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Dispatcher
import SystemOps
import CoreGraphics
// Blueprint: | `TurnCardReadout.swift` | `MacChatTurnCardModel`, `TurnCardReadout` and `MacChatTurnCardFormat`: display-only lifecycle, approval, visibility and whole-second timing projection; canonical turn state and approval records remain authoritative |

/// Display-only projection of one accepted turn. Every field is derived; none
/// is stored, mutated, or remembered by the view layer.
public struct MacChatTurnCardModel: Sendable, Equatable {
    /// Visual register. Deliberately separate from phase so that
    /// outcome-unknown can never be rendered with the success or failure
    /// treatment even if a future phase is added to the working family.
    public enum Tone: Sendable, Equatable {
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

    public let identity: MacChatTurnIdentity
    /// The effective phase, including the derived observational `.stalled`.
    public let phase: TurnPresentationPhase
    public let title: String
    public let detail: String?
    public let delegateName: String?
    public let tone: Tone
    public let symbolName: String
    public let isTerminal: Bool
    public let showsLiveIndicator: Bool
    /// Wall time the turn has been open (live) or was open (terminal).
    public let elapsed: TimeInterval
    /// Seconds since the last observed movement; `nil` once terminal, because
    /// a settled turn has nothing left to move.
    public let secondsSinceMovement: TimeInterval?
    /// A stop was requested and no terminal evidence has arrived yet.
    /// Requesting a stop is not proof the turn stopped.
    public let cancellationPending: Bool
    /// The canonical approval this turn asked for, if any. Projected from the
    /// ApprovalInbox rows the app already holds — the card stores no approval
    /// state of its own and decides nothing.
    public let approval: MacChatTurnCardApproval?

    /// A live clock advances the timing readout alone; nil keeps the projected timing frozen.
    public var clock: Clock? = nil

    /// Thinking begins here while nothing has been said or done; the title counts elapsed time from this instant.
    public var thinkingSince: Date? = nil
    /// Her reply text is arriving and nothing else is going on: the line
    /// that said "Thinking…" says how long she thought.
    public var thoughtFor: TimeInterval? = nil

    /// Raw inputs for the trailing readout. Deliberately the same three
    /// timestamps the projection uses, so the self-advancing readout and a
    /// re-projection can never disagree about what second it is.
    public struct Clock: Equatable, Sendable {
        public let startedAt: Date
        public let endedAt: Date?
        public let lastMovementAt: Date
        public let isTerminal: Bool

        /// Whole seconds, matching `TurnCardReadout.wholeSeconds`:
        /// the readout shows seconds, so sub-second churn would re-render the
        /// text at token rate for a string that never changes.
        public static func wholeSeconds(_ interval: TimeInterval) -> TimeInterval {
            guard interval.isFinite, interval > 0 else { return 0 }
            return interval.rounded(.down)
        }

        public func elapsed(at instant: Date) -> TimeInterval {
            Self.wholeSeconds((endedAt ?? instant).timeIntervalSince(startedAt))
        }

        public func secondsSinceMovement(at instant: Date) -> TimeInterval? {
            isTerminal ? nil : Self.wholeSeconds(instant.timeIntervalSince(lastMovementAt))
        }
    }

    /// True only while the card still offers something to click. A settled
    /// card with no pending decision floats over the transcript and must be
    /// inert; one holding a live approval must not be.
    public var hasControls: Bool {
        !isTerminal || approval?.isActionable == true
    }

    /// Spoken form of the trailing timing readout. The visual string joins its
    /// parts with a middle dot and uses monospaced digits; read verbatim by
    /// VoiceOver that becomes punctuation noise, so the same facts are spoken
    /// as a sentence instead.
    public var spokenMeta: String {
        MacChatTurnCardFormat.metaLine(
            elapsed: elapsed,
            secondsSinceMovement: secondsSinceMovement,
            isTerminal: isTerminal,
            separator: ", "
        )
    }
}

public enum TurnCardReadout {
    /// Threshold at which "no movement" becomes worth saying out loud. Below
    /// the stall threshold this is informational only, not a verdict.
    public static let movementNoticeAfter: TimeInterval = 20

    /// Identity and settled phase decide visibility, never the clock; only an unknown terminal outcome needs a card beyond the transcript.
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

    /// Pending or unproven approvals keep their turn's card visible, independently of the clock.
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
        at instant: Date,
        approvals: [ApprovalRecord] = [],
        parseTimestamp: (String) -> Date?,
        stalledAfter: TimeInterval = TurnPresentationReducer.defaultStalledAfter
    ) -> MacChatTurnCardModel? {
        // Identity fence. A card belongs to exactly one session and one turn;
        // a state routed to the wrong surface renders nothing rather than
        // cross-rendering another conversation's work.
        guard let state,
              isVisible(state, sessionId: sessionId, approvals: approvals, parseTimestamp: parseTimestamp) else { return nil }

        let approval = approval(for: state, approvals: approvals, parseTimestamp: parseTimestamp)
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

        // Keep the decision reachable, but acknowledge Stop until the turn
        // actually settles even when an approval is still pending.
        let ownedApproval = approvalOwnsCard && !cancellationPending ? approval : nil
        // Plain work: no approval, no Stop pending, no tool or delegate line.
        let plain = !isTerminal && ownedApproval == nil && !cancellationPending
            && presentation.currentAction == nil
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
                    ?? detail(phase: phase, currentAction: presentation.currentAction),
            delegateName: presentation.delegateName,
            tone: ownedApproval.map(tone(forApproval:)) ?? tone(for: phase),
            symbolName: ownedApproval.map(symbolName(forApproval:)) ?? symbolName(for: phase),
            isTerminal: isTerminal,
            // A turn waiting on a person is not moving, whatever its last
            // lifecycle event was.
            showsLiveIndicator: ownedApproval == nil && !isTerminal && !cancellationPending && isMoving(phase),
            elapsed: elapsed,
            secondsSinceMovement: sinceMovement,
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

    /// The approval's own words, used when the approval owns the card.
    public static func approvalTitle(for approval: MacChatTurnCardApproval) -> String {
        switch approval.outcome {
        case .pending:
            // WHO is the first thing the person needs when the asker is not
            // them: "Approve shell?" reads like her own request.
            if let requester = approval.requester {
                return "\(requester) asked: approve \(approval.toolName)?"
            }
            return "Approve \(approval.toolName)?"
        case .approved: return "Approved \(approval.toolName)"
        case .denied: return "Denied \(approval.toolName)"
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
            // Never rendered: `card(for:)` returns nil for a completed turn.
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

public enum MacChatTurnCardFormat {
    /// Seconds under a minute, then m/s, then h/m; invalid or unrepresentable
    /// elapsed intervals have no duration reading.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0,
              let total = Int(exactly: seconds.rounded()) else { return "Duration unavailable" }
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

    public static func elapsedPhrase(_ seconds: TimeInterval, isTerminal: Bool) -> String {
        isTerminal ? "Ran for \(duration(seconds))" : "\(duration(seconds)) elapsed"
    }

    /// Only worth saying once movement has actually gone quiet.
    /// The one place the timing readout is assembled, so the visual line, the
    /// spoken line, and the model's own `spokenMeta` cannot drift apart.
    public static func metaLine(
        elapsed: TimeInterval,
        secondsSinceMovement: TimeInterval?,
        isTerminal: Bool,
        separator: String
    ) -> String {
        var parts = [elapsedPhrase(elapsed, isTerminal: isTerminal)]
        if let movement = movementPhrase(secondsSinceMovement) {
            parts.append(movement)
        }
        return parts.joined(separator: separator)
    }

    public static func movementPhrase(_ secondsSinceMovement: TimeInterval?) -> String? {
        guard let secondsSinceMovement,
              secondsSinceMovement >= TurnCardReadout.movementNoticeAfter else {
            return nil
        }
        return "no movement for \(duration(secondsSinceMovement))"
    }
}
