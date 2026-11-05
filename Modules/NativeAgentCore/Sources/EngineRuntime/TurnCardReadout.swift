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
// Blueprint: | `TurnCardReadout.swift` | `MacChatTurnCardModel`, `TurnCardReadout`, `MacChatTurnCardFormat`; Derived lifecycle presentation |

/// Derive every card field from evidence; views keep no mutable turn state.
public struct MacChatTurnCardModel: Sendable, Equatable {
    /// Keep visual register separate from phase so unknown outcomes cannot acquire success or failure treatment.
    public enum Tone: Sendable, Equatable {
        case working
        /// Observed stalls are not terminal errors.
        case attention
        /// Unknown terminal outcomes are neither success nor failure.
        case unresolved
        /// Terminal failure requires typed evidence.
        case failed
        /// Terminal stop requires typed evidence.
        case canceled
    }

    public let identity: MacChatTurnIdentity
    public let phase: TurnPresentationPhase
    public let title: String
    public let detail: String?
    public let delegateName: String?
    public let tone: Tone
    public let symbolName: String
    public let isTerminal: Bool
    public let showsLiveIndicator: Bool
    public let elapsed: TimeInterval
    /// Terminal turns have no remaining movement, so movement age is nil.
    public let secondsSinceMovement: TimeInterval?
    /// A Stop request is not proof of settlement.
    public let cancellationPending: Bool
    /// Read approvals from the existing inbox; the card keeps no approval state or authority.
    public let approval: MacChatTurnCardApproval?

    /// Advance timing only with a live clock; nil freezes the projection.
    public var clock: Clock? = nil

    public var thinkingSince: Date? = nil
    /// When reply text arrives alone, retain the duration spent thinking.
    public var thoughtFor: TimeInterval? = nil

    /// Use the same three timestamps for projection and live readout so their seconds cannot disagree.
    public struct Clock: Equatable, Sendable {
        public let startedAt: Date
        public let endedAt: Date?
        public let lastMovementAt: Date
        public let isTerminal: Bool

        /// Quantize to whole seconds so token-rate movement cannot re-render unchanged text.
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

    /// Settled cards without decisions must be inert; live approvals remain clickable.
    public var hasControls: Bool {
        !isTerminal || approval?.isActionable == true
    }

    /// Speak timing as a sentence so VoiceOver does not read visual punctuation as noise.
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
    /// Quiet movement below stall threshold is informational, never a verdict.
    public static let movementNoticeAfter: TimeInterval = 20

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
        at instant: Date,
        approvals: [ApprovalRecord] = [],
        parseTimestamp: (String) -> Date?,
        stalledAfter: TimeInterval = TurnPresentationReducer.defaultStalledAfter
    ) -> MacChatTurnCardModel? {
        // Require exact session and turn identity so a routed state cannot expose another conversation’s card.
        guard let state,
              isVisible(state, sessionId: sessionId, approvals: approvals, parseTimestamp: parseTimestamp) else { return nil }

        let approval = approval(for: state, approvals: approvals, parseTimestamp: parseTimestamp)
        let presentation = state.presentation
        let isTerminal = presentation.isTerminal
        let phase = isTerminal
            ? presentation.phase
            : state.effectivePhase(at: instant, stalledAfter: stalledAfter)
        // After completion, only unproven approval outcomes retain the card, and the approval owns its words.
        let approvalOwnsCard = approval?.outcome == .pending
            || (phase == .completed && approval?.keepsCardVisible == true)
        guard phase != .completed || approvalOwnsCard else { return nil }

        // Quantize movement to whole seconds so streamed tokens cannot drive card updates faster than its displayed cadence.
        let sinceMovement = isTerminal
            ? nil
            : wholeSeconds(instant.timeIntervalSince(presentation.lastMovementAt))
        let elapsedEnd = presentation.endedAt ?? instant
        let elapsed = wholeSeconds(elapsedEnd.timeIntervalSince(presentation.startedAt))
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

    /// Use the approval’s own words when it owns the card.
    public static func approvalTitle(for approval: MacChatTurnCardApproval) -> String {
        switch approval.outcome {
        case .pending:
            // Name third-party askers first so requests cannot appear to be the agent’s own.
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

public enum MacChatTurnCardFormat {
    /// Invalid or unrepresentable intervals have no duration reading.
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

    /// Assemble timing once so visual, spoken and model metadata cannot drift; name quiet only after movement actually pauses.
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
